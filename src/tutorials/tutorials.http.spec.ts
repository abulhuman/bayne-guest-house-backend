import { INestApplication, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { PassportModule } from '@nestjs/passport';
import { Test } from '@nestjs/testing';
import type { Role } from '@prisma/client';
import {
  cpSync,
  chmodSync,
  copyFileSync,
  symlinkSync,
  unlinkSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import request from 'supertest';
import type { Server } from 'node:http';
import { parseManifest } from './tutorial-manifest';
import { MEDIA_RETRY_MS, type TutorialView } from './tutorials.service';
import { fakeUsers } from '../auth/fake-users';
import { JwtStrategy } from '../auth/jwt.strategy';
import { UsersService } from '../users/users.service';
import { signMediaPath } from './signed-url';
import { TutorialsModule } from './tutorials.module';

const JWT_SECRET = 'tutorials-http-jwt-secret';
const SIGNING_SECRET = 'tutorials-http-signing-secret-0123456789';
const FIXTURES = join(__dirname, 'fixtures');
const STORE_VIDEO = 'store-receive-stock.ca14fc82.mp4';

const binary = (
  res: request.Response,
  done: (err: Error | null, body: Buffer) => void,
) => {
  const chunks: Buffer[] = [];
  res.on('data', (chunk: Buffer) => chunks.push(chunk));
  res.on('end', () => done(null, Buffer.concat(chunks)));
};

async function boot(env: Record<string, string | undefined>) {
  const saved = { ...process.env };
  const variables = { TUTORIALS_SIGNING_SECRET_FILE: undefined, ...env };
  Object.assign(process.env, { JWT_SECRET, ...variables });
  for (const [key, value] of Object.entries(variables))
    if (value === undefined) delete process.env[key];
  const users = fakeUsers();
  try {
    const moduleRef = await Test.createTestingModule({
      imports: [PassportModule, TutorialsModule],
      providers: [
        JwtStrategy,
        ConfigService,
        { provide: UsersService, useValue: users.service },
      ],
    }).compile();
    const app = moduleRef.createNestApplication();
    await app.init();
    return { app, users };
  } finally {
    process.env = saved;
  }
}

describe('Tutorials over HTTP', () => {
  const jwt = new JwtService({ secret: JWT_SECRET });
  let dir: string;
  let app: INestApplication;
  let tokens: Record<'reception' | 'store' | 'security' | 'manager', string>;

  beforeAll(async () => {
    dir = mkdtempSync(join(tmpdir(), 'tutorials-http-'));
    cpSync(FIXTURES, dir, { recursive: true });
    writeFileSync(
      join(dir, 'unlisted.0123abcd.mp4'),
      readFileSync(join(FIXTURES, STORE_VIDEO)),
    );
    writeFileSync(join(dir, '.env'), 'JWT_SECRET=leaked');
    const booted = await boot({
      TUTORIALS_DIR: dir,
      TUTORIALS_SIGNING_SECRET: SIGNING_SECRET,
    });
    app = booted.app;
    const as = (role: Role, name: string) =>
      jwt.sign({ sub: booted.users.add({ role, name }) });
    tokens = {
      reception: as('reception', 'Hodan Warsame'),
      store: as('store', 'Ayaan Abdi'),
      security: as('security', 'Mohamed Yusuf'),
      manager: as('manager', 'Fadumo Hassan'),
    };
  });
  afterAll(async () => {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  });

  const list = (token?: string) => {
    const req = request(app.getHttpServer() as Server).get('/tutorials');
    return token ? req.set('Authorization', `Bearer ${token}`) : req;
  };
  const media = (path: string) =>
    request(app.getHttpServer() as Server)
      .get(path)
      .buffer(true)
      .parse(binary);
  const names = (body: unknown) =>
    parseManifest({ version: 1, tutorials: body }).tutorials.map((t) => t.name);
  const signed = (file: string, nowSec = Math.floor(Date.now() / 1000)) =>
    signMediaPath(SIGNING_SECRET, file, nowSec);

  describe('GET /tutorials', () => {
    it.each([
      [
        'reception',
        ['anyone-login-wrong-password', 'reception-create-booking'],
      ],
      ['store', ['anyone-login-wrong-password', 'store-receive-stock']],
      ['security', ['anyone-login-wrong-password']],
      [
        'manager',
        [
          'admin-add-staff',
          'anyone-login-wrong-password',
          'reception-create-booking',
          'store-receive-stock',
        ],
      ],
    ] as const)(
      'returns only the entries whose audience holds %s',
      async (role, expected) => {
        const res = await list(tokens[role]).expect(200);
        expect(names(res.body)).toEqual(expected);
        for (const tutorial of res.body as TutorialView[])
          expect(tutorial.audience).toContain(role);
      },
    );

    it('adds signed one-hour videoUrl and posterUrl to each manifest entry', async () => {
      const before = Math.floor(Date.now() / 1000);
      const res = await list(tokens.reception).expect(200);
      const booking = (res.body as TutorialView[]).find(
        (t) => t.name === 'reception-create-booking',
      )!;
      expect(booking).toMatchObject({
        title: 'Book a room for a walk-in guest',
        video: 'reception-create-booking.6d3ab696.mp4',
        poster: 'reception-create-booking.24f394c2.jpg',
      });
      expect(booking.videoUrl).toMatch(
        /^\/tutorials\/media\/reception-create-booking\.6d3ab696\.mp4\?exp=\d+&sig=[\w-]{43}$/,
      );
      expect(booking.posterUrl).toMatch(
        /^\/tutorials\/media\/reception-create-booking\.24f394c2\.jpg\?exp=\d+&sig=[\w-]{43}$/,
      );
      const exp = Number(
        new URL(booking.videoUrl, 'http://x').searchParams.get('exp'),
      );
      expect(exp - before).toBeGreaterThanOrEqual(3600);
      expect(exp - before).toBeLessThanOrEqual(3601);
    });

    it('answers 401 without a token, with a bad token, and with an expired token', async () => {
      await list().expect(401);
      await list('not-a-jwt').expect(401);
      const expired = jwt.sign({
        sub: 1,
        exp: Math.floor(Date.now() / 1000) - 60,
      });
      await list(expired).expect(401);
    });
  });

  describe('GET /tutorials/media/:file', () => {
    it('serves the whole file from a URL the list handed out', async () => {
      const response = await list(tokens.store).expect(200);
      const body = response.body as TutorialView[];
      const stock = body.find((t) => t.name === 'store-receive-stock')!;
      const res = await media(stock.videoUrl).expect(200);
      expect(res.headers['content-type']).toBe('video/mp4');
      expect(res.headers['cache-control']).toBe('private, max-age=3600');
      expect(res.headers['accept-ranges']).toBe('bytes');
      expect(res.body).toEqual(readFileSync(join(FIXTURES, STORE_VIDEO)));

      const poster = await media(stock.posterUrl).expect(200);
      expect(poster.headers['content-type']).toBe('image/jpeg');
    });

    it('refuses a cached media path replaced with a symlink', async () => {
      await list(tokens.store).expect(200);
      const outside = mkdtempSync(join(tmpdir(), 'tutorial-outside-'));
      const target = join(outside, 'key');
      writeFileSync(target, 'outside-secret');
      const path = join(dir, STORE_VIDEO);
      unlinkSync(path);
      symlinkSync(target, path);
      try {
        await media(signed(STORE_VIDEO)).expect(404);
      } finally {
        unlinkSync(path);
        copyFileSync(join(FIXTURES, STORE_VIDEO), path);
        rmSync(outside, { recursive: true, force: true });
      }
    });

    it('answers a Range request with 206 and the exact slice', async () => {
      const whole = readFileSync(join(FIXTURES, STORE_VIDEO));
      const res = await media(signed(STORE_VIDEO))
        .set('Range', 'bytes=1000-1999')
        .expect(206);
      expect(res.headers['content-range']).toBe(
        `bytes 1000-1999/${whole.length}`,
      );
      expect(res.headers['content-length']).toBe('1000');
      expect(res.body).toEqual(whole.subarray(1000, 2000));
    });

    it('answers an unsatisfiable Range with 416', async () => {
      const res = await media(signed(STORE_VIDEO))
        .set('Range', 'bytes=999999-')
        .expect(416);
      expect(res.headers['content-range']).toMatch(/^bytes \*\/\d+$/);
    });

    it('answers 403 for a tampered sig, a tampered exp, an expired link, and no signature', async () => {
      const url = new URL(signed(STORE_VIDEO), 'http://x');
      const sig = url.searchParams.get('sig')!;
      const exp = Number(url.searchParams.get('exp'));
      const path = url.pathname;
      await media(
        `${path}?exp=${exp}&sig=${sig[0] === 'A' ? 'B' : 'A'}${sig.slice(1)}`,
      ).expect(403);
      await media(`${path}?exp=${exp + 1}&sig=${sig}`).expect(403);
      await media(
        signed(STORE_VIDEO, Math.floor(Date.now() / 1000) - 3601),
      ).expect(403);
      await media(path).expect(403);
    });

    it('does not let a signature for one file open another', async () => {
      const url = new URL(signed(STORE_VIDEO), 'http://x');
      await media(
        `/tutorials/media/reception-create-booking.6d3ab696.mp4${url.search}`,
      ).expect(403);
    });

    it.each([
      [
        'a file in the directory but not in the manifest',
        'unlisted.0123abcd.mp4',
      ],
      ['the manifest itself', 'manifest.json'],
      ['a dotfile', '.env'],
      ['a traversal', '../.env'],
      ['an encoded traversal', '..%2F.env'],
    ])('answers 404 for %s, even when signed', async (_label, file) => {
      const res = await media(
        signMediaPath(
          SIGNING_SECRET,
          file,
          Math.floor(Date.now() / 1000),
        ).replace(encodeURIComponent(file), file),
      ).expect(404);
      expect(Buffer.isBuffer(res.body)).toBe(true);
      expect((res.body as Buffer).toString()).not.toContain('leaked');
    });
  });

  describe('manifest reload', () => {
    const manifestPath = () => join(dir, 'manifest.json');
    const publish = (body: string) => {
      writeFileSync(join(dir, 'manifest.json.tmp'), body);
      renameSync(join(dir, 'manifest.json.tmp'), manifestPath());
    };
    const original = readFileSync(join(FIXTURES, 'manifest.json'), 'utf8');
    afterEach(() => {
      jest.restoreAllMocks();
      publish(original);
    });

    it('picks up a renamed-in manifest without a restart', async () => {
      const manifest = parseManifest(JSON.parse(original));
      manifest.tutorials = manifest.tutorials.filter(
        (t: { name: string }) => t.name !== 'reception-create-booking',
      );
      publish(JSON.stringify(manifest));
      expect(names((await list(tokens.reception).expect(200)).body)).toEqual([
        'anyone-login-wrong-password',
      ]);
      await media(signed('reception-create-booking.24f394c2.jpg')).expect(200);
    });

    it('fails closed with 503 on an invalid manifest and recovers on the next good publish', async () => {
      const bad = parseManifest(JSON.parse(original));
      const invalid = {
        ...bad,
        tutorials: [{ ...bad.tutorials[0], audience: ['chef'] }],
      };
      publish(JSON.stringify(invalid));
      await list(tokens.reception).expect(503);
      await media(signed(STORE_VIDEO)).expect(503);
      publish(original);
      expect(names((await list(tokens.reception).expect(200)).body)).toEqual([
        'anyone-login-wrong-password',
        'reception-create-booking',
      ]);
    });

    it('bounds anonymous unreadable-manifest failures and heals after five seconds', async () => {
      let now = Date.now();
      jest.spyOn(Date, 'now').mockImplementation(() => now);
      const logged = jest
        .spyOn(Logger.prototype, 'error')
        .mockImplementation(() => undefined);
      publish(original);
      chmodSync(manifestPath(), 0);
      try {
        for (let i = 0; i < 100; i++) {
          const res = await request(app.getHttpServer() as Server)
            .get(`/tutorials/media/${STORE_VIDEO}`)
            .expect(503);
          expect(res.body).toEqual({
            statusCode: 503,
            message: 'Tutorial storage is unavailable',
            error: 'Service Unavailable',
          });
        }
        expect(logged).toHaveBeenCalledTimes(1);
        expect(logged).toHaveBeenCalledWith(
          'Tutorial storage could not be read (EACCES)',
        );
        chmodSync(manifestPath(), 0o644);
        now += MEDIA_RETRY_MS - 1;
        await list(tokens.reception).expect(503);
        now += 1;
        await list(tokens.reception).expect(200);
        await media(signed(STORE_VIDEO)).expect(200);
        expect(logged).toHaveBeenCalledTimes(1);
      } finally {
        chmodSync(manifestPath(), 0o644);
      }
    });

    it('retries a manifest whose media was missing once the file appears and the retry window passes', async () => {
      let now = Date.now();
      jest.spyOn(Date, 'now').mockImplementation(() => now);
      const aside = join(dir, 'aside.mp4');
      renameSync(join(dir, STORE_VIDEO), aside);
      publish(original);
      await list(tokens.reception).expect(503);
      await media(signed(STORE_VIDEO)).expect(503);
      renameSync(aside, join(dir, STORE_VIDEO));
      now += MEDIA_RETRY_MS;
      expect(names((await list(tokens.reception).expect(200)).body)).toEqual([
        'anyone-login-wrong-password',
        'reception-create-booking',
      ]);
      await media(signed(STORE_VIDEO)).expect(200);
    });

    it('returns an empty list while no manifest is published', async () => {
      rmSync(manifestPath());
      expect((await list(tokens.reception).expect(200)).body).toEqual([]);
      await media(signed(STORE_VIDEO)).expect(404);
    });
  });
});

describe('Tutorials store configuration', () => {
  it('boots with the store off when TUTORIALS_DIR is unset, listing nothing and serving nothing', async () => {
    const { app, users } = await boot({
      TUTORIALS_DIR: undefined,
      TUTORIALS_SIGNING_SECRET: undefined,
    });
    const token = new JwtService({ secret: JWT_SECRET }).sign({
      sub: users.add({ role: 'reception', name: 'Hodan Warsame' }),
    });
    try {
      const res = await request(app.getHttpServer() as Server)
        .get('/tutorials')
        .set('Authorization', `Bearer ${token}`)
        .expect(200);
      expect(res.body).toEqual([]);
      await request(app.getHttpServer() as Server)
        .get(
          signMediaPath(
            SIGNING_SECRET,
            STORE_VIDEO,
            Math.floor(Date.now() / 1000),
          ),
        )
        .expect(404);
    } finally {
      await app.close();
    }
  });

  it('refuses to boot when TUTORIALS_DIR is set without TUTORIALS_SIGNING_SECRET', async () => {
    await expect(
      boot({ TUTORIALS_DIR: FIXTURES, TUTORIALS_SIGNING_SECRET: undefined }),
    ).rejects.toThrow(
      'TUTORIALS_SIGNING_SECRET or TUTORIALS_SIGNING_SECRET_FILE is required when TUTORIALS_DIR is set',
    );
  });

  it('refuses to boot with a signing secret shorter than 32 characters', async () => {
    await expect(
      boot({ TUTORIALS_DIR: FIXTURES, TUTORIALS_SIGNING_SECRET: 'short' }),
    ).rejects.toThrow(
      'TUTORIALS_SIGNING_SECRET must be at least 32 characters',
    );
  });
});
