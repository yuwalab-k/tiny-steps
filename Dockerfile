FROM perl:5.38

WORKDIR /app

RUN cpanm Mojolicious

COPY . .

EXPOSE 3002

CMD ["morbo", "app.pl", "-l", "http://0.0.0.0:3002"]
