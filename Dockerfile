FROM nginx:1.27-alpine

ARG BUILD_ID=dev
COPY sample-app/index.html /tmp/index.html
RUN sed "s/__BUILD_ID__/${BUILD_ID}/g" /tmp/index.html > /usr/share/nginx/html/index.html
