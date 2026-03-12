FROM perl:5.38

WORKDIR /app

COPY cpanfile cpanfile
RUN cpanm --notest --installdeps .

COPY . .

EXPOSE 3002

CMD ["morbo", "app.pl", "-l", "http://0.0.0.0:3002"]
