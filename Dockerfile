# syntax=docker/dockerfile:1.7

FROM hugomods/hugo:exts AS build
WORKDIR /site
COPY . /site
RUN hugo mod tidy && hugo mod vendor
RUN hugo --minify

FROM nginx:1.27-alpine
COPY --from=build /site/public /usr/share/nginx/html
COPY <<'EOF' /etc/nginx/conf.d/default.conf
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ $uri/index.html =404;
    }

    location = /healthz {
        access_log off;
        return 200 'ok\n';
        add_header Content-Type text/plain;
    }
}
EOF
EXPOSE 80
