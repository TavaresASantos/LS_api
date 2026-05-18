FROM node:20-alpine

RUN apk add --no-cache curl

WORKDIR /usr/src/app

COPY package*.json ./

RUN npm ci --only=production

COPY . .

USER node

EXPOSE 3000

CMD ["node", "src/index.js"]