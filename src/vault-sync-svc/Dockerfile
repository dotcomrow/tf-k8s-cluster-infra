FROM node:18

# Set working directory
WORKDIR /usr/src/app

# Copy package manifests first for better caching
COPY package*.json tsconfig.json ./

# Install dependencies
RUN npm install

# Copy the rest of the app
COPY . .

# Build TypeScript
RUN npm run build

# Expose Cloud Run's default port
EXPOSE 8080

# Run compiled app
CMD ["node", "dist/sync.js"]
