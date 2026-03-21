use Mojolicious::Lite;
use DBI;

my $DB_PATH = app->home->rel_file('db/tiny_steps.sqlite');

helper db => sub {
  state $dbh = DBI->connect(
    "dbi:SQLite:dbname=$DB_PATH",
    "", "",
    { RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1 }
  );
  return $dbh;
};

helper ensure_db => sub {
  state $done = 0;
  return if $done;
  my $c = shift;

  # Drop old unused tables
  for my $tbl (qw(ai_pending ai_messages event_logs task_logs tasks)) {
    $c->db->do("DROP TABLE IF EXISTS $tbl");
  }

  $c->db->do(q{
    CREATE TABLE IF NOT EXISTS goals (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      parent_id  INTEGER REFERENCES goals(id),
      title      TEXT NOT NULL,
      completed  INTEGER NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0,
      archived   INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  });
  $c->db->do('CREATE INDEX IF NOT EXISTS idx_goals_parent ON goals(parent_id)');
  # Safe migration for existing DBs
  eval { $c->db->do("ALTER TABLE goals ADD COLUMN completed INTEGER NOT NULL DEFAULT 0") };

  my ($n) = $c->db->selectrow_array('SELECT COUNT(*) FROM goals WHERE archived = 0');
  if ($n == 0) {
    $c->db->do("INSERT INTO goals (title) VALUES (?)", undef, 'メインゴール');
  }

  $done = 1;
};

helper fetch_node => sub {
  my ($c, $id) = @_;
  $c->db->selectrow_hashref(
    'SELECT * FROM goals WHERE id = ? AND archived = 0',
    undef, $id
  );
};

helper fetch_children => sub {
  my ($c, $parent_id, %opt) = @_;
  my (@cond, @bind);
  if (defined $parent_id) {
    push @cond, 'g.parent_id = ?'; push @bind, $parent_id;
  } else {
    push @cond, 'g.parent_id IS NULL';
  }
  if (exists $opt{completed}) {
    push @cond, 'g.completed = ?'; push @bind, $opt{completed};
  }
  push @cond, 'g.archived = 0';
  my $where = join(' AND ', @cond);
  my $sql = qq{SELECT g.*, (SELECT COUNT(*) FROM goals WHERE parent_id = g.id AND archived = 0) AS child_count
    FROM goals g WHERE $where ORDER BY g.sort_order, g.id};
  $c->db->selectall_arrayref($sql, { Slice => {} }, @bind);
};

helper fetch_ancestors => sub {
  my ($c, $id) = @_;
  my @list;
  while (defined $id) {
    my $n = $c->fetch_node($id);
    last unless $n;
    unshift @list, $n;
    $id = $n->{parent_id};
  }
  return \@list;
};

# ----------------------------------------------------------------
get '/' => sub {
  my $c = shift;
  $c->ensure_db;
  my $roots = $c->fetch_children(undef, completed => 0);
  $c->stash(roots => $roots);
  $c->render(template => 'home');
};

get '/archive' => sub {
  my $c = shift;
  $c->ensure_db;
  my $charts = $c->fetch_children(undef, completed => 1);
  $c->stash(charts => $charts);
  $c->render(template => 'archive');
};

get '/mandala/:id' => sub {
  my $c = shift;
  $c->ensure_db;
  my $node = $c->fetch_node($c->param('id'));
  return $c->reply->not_found unless $node;

  my $children = $c->fetch_children($node->{id});
  my $ancestors = $c->fetch_ancestors($node->{parent_id});
  my ($child_count) = $c->db->selectrow_array(
    'SELECT COUNT(*) FROM goals WHERE parent_id = ? AND archived = 0', undef, $node->{id}
  );

  $c->stash(
    node        => $node,
    children    => $children,
    ancestors   => $ancestors,
    child_count => $child_count,
  );
  $c->render(template => 'mandala');
};

post '/goals' => sub {
  my $c = shift;
  $c->ensure_db;
  my $title = $c->param('title') // '';
  $title =~ s/^\s+|\s+$//g;
  if ($title ne '') {
    $c->db->do("INSERT INTO goals (title) VALUES (?)", undef, $title);
    return $c->redirect_to('/mandala/' . $c->db->sqlite_last_insert_rowid);
  }
  $c->redirect_to('/');
};

post '/goals/:id/child' => sub {
  my $c = shift;
  $c->ensure_db;
  my $pid   = $c->param('id');
  my $title = $c->param('title') // '';
  $title =~ s/^\s+|\s+$//g;

  my $slot = $c->param('slot') // -1;
  $slot = int($slot);
  $slot = -1 if $slot < 0 || $slot > 7;

  if ($title ne '') {
    my $kids = $c->fetch_children($pid);
    if (@$kids < 8) {
      # slot が指定されていてそのスロットが空なら指定位置に、そうでなければ末尾
      my %taken = map { $_->{sort_order} => 1 } @$kids;
      my $order = ($slot >= 0 && !$taken{$slot}) ? $slot : scalar(@$kids);
      $c->db->do(
        "INSERT INTO goals (parent_id, title, sort_order) VALUES (?, ?, ?)",
        undef, $pid, $title, $order
      );
    }
  }

  my $node     = $c->fetch_node($pid);
  my $children = $c->fetch_children($pid);
  my $ancestors = $c->fetch_ancestors($node->{parent_id});
  my ($child_count) = $c->db->selectrow_array(
    'SELECT COUNT(*) FROM goals WHERE parent_id = ? AND archived = 0', undef, $node->{id}
  );
  $c->stash(node => $node, children => $children, ancestors => $ancestors, child_count => $child_count);
  $c->render(template => 'partials/mandala_grid');
};

post '/goals/:id/rename' => sub {
  my $c = shift;
  $c->ensure_db;
  my $id    = $c->param('id');
  my $title = $c->param('title') // '';
  $title =~ s/^\s+|\s+$//g;
  $c->db->do(
    "UPDATE goals SET title = ?, updated_at = datetime('now') WHERE id = ?",
    undef, $title || '無題', $id
  ) if $title ne '';
  $c->redirect_to("/mandala/$id");
};

sub _propagate_completion {
  my ($c, $parent_id) = @_;
  return unless defined $parent_id;

  my ($total) = $c->db->selectrow_array(
    'SELECT COUNT(*) FROM goals WHERE parent_id = ? AND archived = 0', undef, $parent_id);
  my ($done) = $c->db->selectrow_array(
    'SELECT COUNT(*) FROM goals WHERE parent_id = ? AND archived = 0 AND completed = 1', undef, $parent_id);

  my $all_done = ($total > 0 && $total == $done) ? 1 : 0;
  $c->db->do(
    "UPDATE goals SET completed = ?, updated_at = datetime('now') WHERE id = ?",
    undef, $all_done, $parent_id
  );

  my $parent = $c->fetch_node($parent_id);
  _propagate_completion($c, $parent->{parent_id}) if $parent && defined $parent->{parent_id};
}

post '/goals/:id/toggle_done' => sub {
  my $c = shift;
  $c->ensure_db;
  my $id   = $c->param('id');
  my $back = $c->param('back');

  my ($current) = $c->db->selectrow_array('SELECT completed FROM goals WHERE id = ?', undef, $id);
  my $new = ($current && $current == 1) ? 0 : 1;
  $c->db->do(
    "UPDATE goals SET completed = ?, updated_at = datetime('now') WHERE id = ?",
    undef, $new, $id
  );

  my $node = $c->fetch_node($id);
  _propagate_completion($c, $node->{parent_id}) if $node && defined $node->{parent_id};

  return $c->redirect_to('/mandala/' . $back) if $back;
  $c->redirect_to("/mandala/$id");
};

post '/goals/:id/delete' => sub {
  my $c = shift;
  $c->ensure_db;
  my $id    = $c->param('id');
  my $node  = $c->fetch_node($id);
  my $parent_id = $node ? $node->{parent_id} : undef;

  # Cascade archive: the node and all descendants
  my $ids = $c->db->selectcol_arrayref(q{
    WITH RECURSIVE desc(id) AS (
      SELECT id FROM goals WHERE id = ?
      UNION ALL
      SELECT g.id FROM goals g JOIN desc d ON g.parent_id = d.id
    )
    SELECT id FROM desc
  }, undef, $id);

  if ($ids && @$ids) {
    my $ph = join(',', ('?') x @$ids);
    $c->db->do("UPDATE goals SET archived = 1, updated_at = datetime('now') WHERE id IN ($ph)", undef, @$ids);
  }

  return $c->redirect_to('/mandala/' . $parent_id) if $parent_id;
  $c->redirect_to('/');
};

app->start;
