import { mkdtempSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { JwtService } from '@nestjs/jwt';

async function signWithEnvFile(contents: string) {
  const envFile = join(mkdtempSync(join(tmpdir(), 'auth-config-')), '.env');
  writeFileSync(envFile, contents);
  delete process.env.JWT_SECRET;
  delete process.env.JWT_EXPIRES_IN;
  jest.resetModules();

  const { Test } = require('@nestjs/testing');
  const { ConfigModule } = require('@nestjs/config');
  const { JwtService: FreshJwtService } = require('@nestjs/jwt');
  const { AuthModule } = require('./auth.module');
  const { PrismaService } = require('../prisma/prisma.service');
  const { PrismaModule } = require('../prisma/prisma.module');

  const moduleRef = await Test.createTestingModule({
    imports: [
      ConfigModule.forRoot({ envFilePath: envFile }),
      PrismaModule,
      AuthModule,
    ],
  })
    .overrideProvider(PrismaService)
    .useValue({})
    .compile();
  const token = moduleRef.get(FreshJwtService).sign({ sub: 1, role: 'admin' });
  return new JwtService({ secret: 'from-env-file' }).verify(token);
}

describe('AuthModule config', () => {
  it('signs with a secret only the env file sets, and a blank expiry means 7 days', async () => {
    const claims = await signWithEnvFile(
      'JWT_SECRET=from-env-file\nJWT_EXPIRES_IN=\n',
    );
    expect(claims.sub).toBe(1);
    expect(claims.exp - claims.iat).toBe(7 * 24 * 60 * 60);
  });

  it('treats a whitespace-only expiry as blank, like the secret', async () => {
    const claims = await signWithEnvFile(
      'JWT_SECRET=from-env-file\nJWT_EXPIRES_IN="  "\n',
    );
    expect(claims.exp - claims.iat).toBe(7 * 24 * 60 * 60);
  });

  it('reads a padded number of seconds as seconds', async () => {
    const claims = await signWithEnvFile(
      'JWT_SECRET=from-env-file\nJWT_EXPIRES_IN=" 3600 "\n',
    );
    expect(claims.exp - claims.iat).toBe(3600);
  });

  it('reads a bare number of seconds as seconds, not milliseconds', async () => {
    const claims = await signWithEnvFile(
      'JWT_SECRET=from-env-file\nJWT_EXPIRES_IN=3600\n',
    );
    expect(claims.exp - claims.iat).toBe(3600);
  });

  it('reads a timespan with a unit', async () => {
    const claims = await signWithEnvFile(
      'JWT_SECRET=from-env-file\nJWT_EXPIRES_IN=12 hours\n',
    );
    expect(claims.exp - claims.iat).toBe(12 * 60 * 60);
  });

  it('refuses to start with an expiry jsonwebtoken cannot parse', async () => {
    await expect(
      signWithEnvFile('JWT_SECRET=from-env-file\nJWT_EXPIRES_IN=7 dayz\n'),
    ).rejects.toThrow('JWT_EXPIRES_IN must be a number of seconds');
  });
});
