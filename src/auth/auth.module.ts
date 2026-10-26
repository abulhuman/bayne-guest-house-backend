import { Module } from '@nestjs/common';
import { PassportModule } from '@nestjs/passport';
import { JwtModule, type JwtSignOptions } from '@nestjs/jwt';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { UsersModule } from '../users/users.module';
import { AuthService } from './auth.service';
import { AuthController } from './auth.controller';
import { JwtStrategy, PasswordChangeJwtStrategy, jwtSecret } from './jwt.strategy';
import { envValue } from '../env';

type TokenLifetime = NonNullable<JwtSignOptions['expiresIn']>;

// The unit-required form of the timespan pattern in ms, which jsonwebtoken parses expiresIn with.
const TIMESPAN =
  /^-?\d*\.?\d+ *(milliseconds?|msecs?|ms|seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w|years?|yrs?|y)$/i;

function isTimespan(value: string): value is Extract<TokenLifetime, string> {
  return TIMESPAN.test(value);
}

// jsonwebtoken reads a unitless string as milliseconds, so '3600' would expire in 3.6 seconds.
function tokenLifetime(config: ConfigService): TokenLifetime {
  const lifetime = envValue(config, 'JWT_EXPIRES_IN') ?? '7d';
  if (/^\d+$/.test(lifetime)) return Number(lifetime);
  if (!isTimespan(lifetime)) {
    throw new Error(
      `JWT_EXPIRES_IN must be a number of seconds or a timespan like "7d", got "${lifetime}"`,
    );
  }
  return lifetime;
}

@Module({
  imports: [
    UsersModule,
    PassportModule,
    ConfigModule,
    JwtModule.registerAsync({
      imports: [ConfigModule],
      inject: [ConfigService],
      useFactory: (config: ConfigService) => ({
        secret: jwtSecret(config),
        signOptions: { expiresIn: tokenLifetime(config) },
      }),
    }),
  ],
  controllers: [AuthController],
  providers: [AuthService, JwtStrategy, PasswordChangeJwtStrategy],
  exports: [PassportModule, JwtModule, JwtStrategy],
})
export class AuthModule {}
