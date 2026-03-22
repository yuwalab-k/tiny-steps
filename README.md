Tiny Steps

概要
-----
Tiny Steps は、大きな目標を小さなステップに分解し、
日々の積み重ねで達成していくためのタスクアプリです。

技術スタック
-------------
- Perl
- Mojolicious
- htmx (フロントエンドの部分更新用)
- Docker / Docker Compose
- SQLite

環境構築
---------
1. リポジトリをクローンまたはディレクトリを作成
2. Docker と Docker Compose がインストールされていることを確認
3. ターミナルでプロジェクトディレクトリに移動

   docker compose up --build

4. ブラウザで以下にアクセス

   http://localhost:3002

データベース
------------
DB ファイルは `db/tiny_steps.sqlite` に作成されます。
アプリ起動時に自動でテーブルが作成されるため、通常は手動での操作は不要です。

### マイグレーションファイルを手動で適用する場合

   sqlite3 db/tiny_steps.sqlite < db/migrations/001_initial_schema.sql

Docker コンテナ内で実行する場合は以下のとおりです。

   docker compose run --rm app sqlite3 db/tiny_steps.sqlite < db/migrations/001_initial_schema.sql

