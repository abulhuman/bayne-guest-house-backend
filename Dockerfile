FROM node:22
COPY --from=oven/bun:1.4.3 /usr/local/bin/bun /usr/local/bin/bun

# Set the working directory inside the container
WORKDIR /usr/src/app

# Copy package.json and bun.lock to the working directory
COPY package.json bun.lock ./
COPY prisma ./prisma/

# Install the application dependencies
RUN bun install --frozen-lockfile

# Copy the rest of the application files
COPY . .

# Build the NestJS application
RUN bun run build

# Expose the application port
EXPOSE 3000

# Command to run the application
CMD ["bun", "run", "start:prod"]

HEALTHCHECK --interval=5m --timeout=3s \
  CMD node -e "fetch('http://localhost:' + (process.env.PORT || '3000') + '/health').then((response) => process.exit(response.ok ? 0 : 1)).catch(() => process.exit(1))"
