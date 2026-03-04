FROM node:18-alpine AS builder
WORKDIR /app
COPY package.json ./
RUN npm install --production

FROM node:18-alpine
WORKDIR /app

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=builder /app/node_modules ./node_modules
COPY package.json ./
COPY src/ ./src/

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
  CMD node -e "const http=require('http');const r=http.get('http://127.0.0.1:3000/health',res=>{process.exit(res.statusCode===200?0:1)});r.on('error',()=>process.exit(1));r.setTimeout(4000,()=>{r.destroy();process.exit(1)});"

CMD ["node", "--require", "./src/tracing.js", "src/server.js"]
