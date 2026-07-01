# Stage 1: Static Asset Validation
FROM alpine:3.18 AS validator
WORKDIR /build

# Copy source directory for validation
COPY src/ .

# Ensure source assets are valid and non-empty
RUN test -f index.html && test -f styles.css
RUN grep -q "Hello from a Scalable AWS Architecture!" index.html

# Stage 2: Run Production Nginx Server
FROM nginx:1.25-alpine
LABEL maintainer="Antigravity Staff Engineer"

# Copy custom Nginx optimization configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Copy verified static assets from stage 1 validator
COPY --from=validator /build/ /usr/share/nginx/html/

# Expose standard HTTP port
EXPOSE 80

# Clean default entrypoints & run Nginx in foreground
CMD ["nginx", "-g", "daemon off;"]
