FROM alpine:3.18 AS validator
WORKDIR /build

COPY src/ .

RUN test -f index.html && test -f styles.css
RUN grep -q "Hello from a Scalable AWS Architecture!" index.html

FROM nginx:1.25-alpine
LABEL maintainer="Antigravity Staff Engineer"

COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=validator /build/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
