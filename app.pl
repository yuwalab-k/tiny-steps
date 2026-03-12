use Mojolicious::Lite;
use DBI;
use Time::Piece;
use Time::Seconds;
use Scalar::Util qw(looks_like_number);
use Mojo::UserAgent;
use Mojo::JSON qw(encode_json decode_json);

my $DB_PATH = app->home->rel_file('db/tiny_steps.sqlite');
my $SCHEMA_PATH = app->home->rel_file('db/schema.sql');

helper db => sub {
  state $dbh = DBI->connect(
    "dbi:SQLite:dbname=$DB_PATH",
    "",
    "",
    {
      RaiseError => 1,
      PrintError => 0,
      AutoCommit => 1,
      sqlite_unicode => 1,
      sqlite_allow_multiple_statements => 1,
    }
  );
  return $dbh;
};

helper ensure_db => sub {
  state $initialized = 0;
  return if $initialized;

  my $c = shift;
  my $dbh = $c->db;

  if (-e $SCHEMA_PATH) {
    my $schema_sql = do {
      local $/;
      open my $fh, '<', $SCHEMA_PATH or die "Unable to read schema.sql: $!";
      <$fh>;
    };
    $dbh->do($schema_sql);
  } else {
    die "Missing schema.sql at $SCHEMA_PATH";
  }

  my ($goal_count) = $dbh->selectrow_array('SELECT COUNT(*) FROM goals');
  if ($goal_count == 0) {
    $dbh->do('INSERT INTO goals (title, deadline, sort_order) VALUES (?, ?, ?)', undef, '中学受験', '2027-02-01', 0);
    my $root_id = $dbh->sqlite_last_insert_rowid;

    $dbh->do('INSERT INTO goals (parent_id, title, sort_order) VALUES (?, ?, ?)', undef, $root_id, '算数', 0);
    my $math_id = $dbh->sqlite_last_insert_rowid;
    $dbh->do('INSERT INTO goals (parent_id, title, sort_order) VALUES (?, ?, ?)', undef, $root_id, '国語', 1);
    my $japanese_id = $dbh->sqlite_last_insert_rowid;

    $dbh->do('INSERT INTO goals (parent_id, title, sort_order) VALUES (?, ?, ?)', undef, $math_id, '計算力', 0);
    my $calc_id = $dbh->sqlite_last_insert_rowid;

    $dbh->do('INSERT INTO tasks (goal_id, title, repeat_type, duration_min, priority) VALUES (?, ?, ?, ?, ?)', undef, $calc_id, '計算ドリル 10問', 'daily', 15, 'medium');
    $dbh->do('INSERT INTO tasks (goal_id, title, repeat_type, duration_min, priority) VALUES (?, ?, ?, ?, ?)', undef, $math_id, '分数問題 5問', 'weekly', 20, 'high');
    $dbh->do('INSERT INTO tasks (goal_id, title, repeat_type, duration_min, priority) VALUES (?, ?, ?, ?, ?)', undef, $japanese_id, '漢字 5個', 'daily', 10, 'medium');
    $dbh->do('INSERT INTO tasks (goal_id, title, repeat_type, duration_min, priority) VALUES (?, ?, ?, ?, ?)', undef, $japanese_id, '音読 10分', 'none', 10, 'low');
  }

  $initialized = 1;
};

sub _today_str { return localtime->ymd; }
sub _week_ago_str { return (localtime - ONE_DAY * 7)->ymd; }

helper fetch_tasks_today => sub {
  my $c = shift;
  my $dbh = $c->db;

  my $today = _today_str();
  my $week_ago = _week_ago_str();

  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        t.id,
        t.title,
        t.repeat_type,
        t.points,
        t.duration_min,
        t.priority,
        g.title AS goal_title,
        (SELECT status FROM task_logs WHERE task_id = t.id AND log_date = ? ORDER BY created_at DESC LIMIT 1) AS today_status,
        (SELECT log_date FROM task_logs WHERE task_id = t.id AND status = 'done' ORDER BY log_date DESC, created_at DESC LIMIT 1) AS last_done_date
      FROM tasks t
      LEFT JOIN goals g ON g.id = t.goal_id
      WHERE t.active = 1
      ORDER BY t.id
    },
    { Slice => {} },
    $today
  );

  my @tasks;
  for my $row (@$rows) {
    my $repeat = $row->{repeat_type} // 'none';
    my $last_done = $row->{last_done_date};
    my $show = 0;

    if ($repeat eq 'daily') {
      $show = 1;
    } elsif ($repeat eq 'weekly') {
      $show = (!defined $last_done) || ($last_done le $week_ago);
    } else {
      $show = !defined $last_done;
    }

    next unless $show;

    $row->{done_today} = ($row->{today_status} // '') eq 'done' ? 1 : 0;
    $row->{duration_min} = looks_like_number($row->{duration_min}) ? 0 + $row->{duration_min} : 0;
    push @tasks, $row;
  }

  return \@tasks;
};

helper fetch_goal_tree => sub {
  my ($c, $root_id) = @_;
  my $dbh = $c->db;

  my $goals = $dbh->selectall_arrayref(
    'SELECT id, parent_id, title, deadline, completed FROM goals WHERE archived = 0 ORDER BY sort_order, id',
    { Slice => {} }
  );
  my $tasks = $dbh->selectall_arrayref(
    'SELECT id, goal_id, title FROM tasks WHERE active = 1 ORDER BY id',
    { Slice => {} }
  );

  my %by_id = map { $_->{id} => { %$_, children => [], tasks => [] } } @$goals;
  my @roots;

  for my $goal (@$goals) {
    if ($goal->{parent_id}) {
      push @{ $by_id{$goal->{parent_id}}{children} }, $by_id{$goal->{id}} if $by_id{$goal->{parent_id}};
    } else {
      push @roots, $by_id{$goal->{id}};
    }
  }

  for my $task (@$tasks) {
    push @{ $by_id{$task->{goal_id}}{tasks} }, $task if $by_id{$task->{goal_id}};
  }

  if ($root_id) {
    return [ $by_id{$root_id} ] if $by_id{$root_id};
  }
  return \@roots;
};

helper goal_has_children => sub {
  my ($c, $goal_id) = @_;
  my ($count) = $c->db->selectrow_array(
    'SELECT COUNT(*) FROM goals WHERE parent_id = ? AND archived = 0',
    undef,
    $goal_id
  );
  return $count && $count > 0 ? 1 : 0;
};

helper archive_goal_tree => sub {
  my ($c, $root_id) = @_;
  my $dbh = $c->db;

  my $ids = $dbh->selectcol_arrayref(
    q{
      WITH RECURSIVE descendants(id) AS (
        SELECT id FROM goals WHERE id = ?
        UNION ALL
        SELECT g.id FROM goals g JOIN descendants d ON g.parent_id = d.id
      )
      SELECT id FROM descendants
    },
    undef,
    $root_id
  );

  return unless $ids && @$ids;
  my $placeholders = join(',', ('?') x scalar(@$ids));

  $dbh->do("UPDATE goals SET archived = 1, updated_at = datetime('now') WHERE id IN ($placeholders)", undef, @$ids);
  $dbh->do("UPDATE tasks SET active = 0, updated_at = datetime('now') WHERE goal_id IN ($placeholders)", undef, @$ids);

  $c->db->do(
    'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
    undef,
    'goal_archived_tree',
    'goal',
    $root_id,
    '{"source":"ui"}'
  );
};

helper goal_has_tasks => sub {
  my ($c, $goal_id) = @_;
  my ($count) = $c->db->selectrow_array(
    'SELECT COUNT(*) FROM tasks WHERE goal_id = ? AND active = 1',
    undef,
    $goal_id
  );
  return $count && $count > 0 ? 1 : 0;
};

helper fetch_goal_options => sub {
  my $c = shift;
  my $tree = $c->fetch_goal_tree;
  my @options;

  my $walk;
  $walk = sub {
    my ($nodes, $depth) = @_;
    for my $node (@$nodes) {
      push @options, {
        id => $node->{id},
        label => ('—' x $depth) . ' ' . $node->{title},
      };
      $walk->($node->{children}, $depth + 1) if @{ $node->{children} || [] };
    }
  };

  $walk->($tree, 0);
  return \@options;
};

helper _order_sql => sub {
  my ($c, $sort, $dir, $allowed, $default_sort) = @_;
  $sort = $default_sort unless $allowed->{$sort};
  $dir = (defined $dir && $dir =~ /^(asc|desc)$/i) ? lc($dir) : 'asc';
  return ($sort, $dir);
};

helper fetch_goal_list => sub {
  my ($c, $params) = @_;
  my $dbh = $c->db;
  $params ||= {};

  my $q = $params->{q} // '';
  my ($sort, $dir) = $c->_order_sql($params->{sort}, $params->{dir}, {
    title => 1,
    deadline => 1,
    created_at => 1,
    updated_at => 1,
  }, 'title');

  my $sql = "SELECT id, parent_id, title, deadline, completed, created_at, updated_at FROM goals WHERE archived = 0 AND title LIKE ? ORDER BY $sort $dir";
  return $dbh->selectall_arrayref($sql, { Slice => {} }, "%$q%");
};

helper fetch_task_list => sub {
  my ($c, $params) = @_;
  my $dbh = $c->db;
  $params ||= {};

  my $q = $params->{q} // '';
  my $priority = $params->{priority} // 'all';
  my $repeat = $params->{repeat} // 'all';
  my $include_archived = $params->{include_archived} ? 1 : 0;

  my %sort_map = (
    title => 't.title',
    duration_min => 't.duration_min',
    priority => 't.priority',
    repeat_type => 't.repeat_type',
    created_at => 't.created_at',
    updated_at => 't.updated_at',
  );
  my ($sort_key, $dir) = $c->_order_sql($params->{sort}, $params->{dir}, {
    map { $_ => 1 } keys %sort_map
  }, 'created_at');
  my $sort = $sort_map{$sort_key};

  my @where = ('t.title LIKE ?');
  my @bind = ("%$q%");
  if ($priority ne 'all') {
    push @where, 't.priority = ?';
    push @bind, $priority;
  }
  if ($repeat ne 'all') {
    push @where, 't.repeat_type = ?';
    push @bind, $repeat;
  }
  if (!$include_archived) {
    push @where, 't.active = 1';
  }

  my $sql = sprintf(
    "SELECT t.id, t.title, t.duration_min, t.priority, t.repeat_type, t.created_at, t.updated_at, t.active, g.title AS goal_title,
            (SELECT status FROM task_logs WHERE task_id = t.id ORDER BY log_date DESC, created_at DESC LIMIT 1) AS last_status
     FROM tasks t
     LEFT JOIN goals g ON g.id = t.goal_id
     WHERE %s
     ORDER BY %s %s",
    join(' AND ', @where),
    $sort, $dir
  );

  return $dbh->selectall_arrayref($sql, { Slice => {} }, @bind);
};

helper fetch_logs_filtered => sub {
  my ($c, $params) = @_;
  my $dbh = $c->db;
  $params ||= {};

  my $from = $params->{from};
  my $to = $params->{to};
  my $type = $params->{type} // 'all';

  my @task_where;
  my @task_bind;
  my @event_where;
  my @event_bind;

  if ($from) {
    push @task_where, 'created_at >= ?';
    push @event_where, 'created_at >= ?';
    push @task_bind, "$from 00:00:00";
    push @event_bind, "$from 00:00:00";
  }
  if ($to) {
    push @task_where, 'created_at <= ?';
    push @event_where, 'created_at <= ?';
    push @task_bind, "$to 23:59:59";
    push @event_bind, "$to 23:59:59";
  }

  my %event_types = map { $_ => 1 } qw(
    goal_created goal_updated goal_archived
    task_created task_updated task_archived
    ai_task_added physical_obtained parent_checked
  );

  my @task_logs;
  my @event_logs;

  if ($type eq 'all' || $type eq 'task_done' || $type eq 'task_undone') {
    if ($type eq 'task_done') {
      push @task_where, "status = 'done'";
    } elsif ($type eq 'task_undone') {
      push @task_where, "status = 'undone'";
    }
    my $task_sql = 'SELECT created_at AS timestamp, ' .
      "CASE status WHEN 'done' THEN 'タスク完了' ELSE 'タスク未完了' END AS action, " .
      '(SELECT title FROM tasks WHERE id = task_id) AS task ' .
      'FROM task_logs' .
      (@task_where ? ' WHERE ' . join(' AND ', @task_where) : '') .
      ' ORDER BY created_at DESC LIMIT 200';
    @task_logs = @{ $dbh->selectall_arrayref($task_sql, { Slice => {} }, @task_bind) };
  }

  if ($type eq 'all' || $event_types{$type}) {
    if ($event_types{$type}) {
      push @event_where, 'event_type = ?';
      push @event_bind, $type;
    }
    my $event_sql = 'SELECT created_at AS timestamp, event_type AS action, ' .
      "CASE target_type WHEN 'task' THEN (SELECT title FROM tasks WHERE id = target_id) " .
      "WHEN 'goal' THEN (SELECT title FROM goals WHERE id = target_id) ELSE NULL END AS task " .
      'FROM event_logs' .
      (@event_where ? ' WHERE ' . join(' AND ', @event_where) : '') .
      ' ORDER BY created_at DESC LIMIT 200';
    @event_logs = @{ $dbh->selectall_arrayref($event_sql, { Slice => {} }, @event_bind) };
  }

  my @combined = sort { $b->{timestamp} cmp $a->{timestamp} } (@task_logs, @event_logs);
  splice(@combined, 200) if @combined > 200;
  return \@combined;
};

helper fetch_latest_task_status => sub {
  my $c = shift;
  my $dbh = $c->db;
  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT t.id AS task_id,
             (SELECT status FROM task_logs WHERE task_id = t.id ORDER BY log_date DESC, created_at DESC LIMIT 1) AS last_status
      FROM tasks t
      WHERE t.active = 1
    },
    { Slice => {} }
  );

  my %status = map { $_->{task_id} => ($_->{last_status} // '') } @$rows;
  return \%status;
};

helper compute_progress_for_tree => sub {
  my ($c, $nodes, $status_map) = @_;

  for my $node (@$nodes) {
    my $total = 0;
    my $done = 0;

    for my $task (@{ $node->{tasks} || [] }) {
      $total++;
      $done++ if ($status_map->{$task->{id}} // '') eq 'done';
    }

    if (@{ $node->{children} || [] }) {
      $c->compute_progress_for_tree($node->{children}, $status_map);
      for my $child (@{ $node->{children} }) {
        $total += $child->{_total_tasks};
        $done += $child->{_done_tasks};
      }
    }

    $node->{_total_tasks} = $total;
    $node->{_done_tasks} = $done;
    $node->{progress} = $total ? int(($done / $total) * 100) : 0;
  }

  return $nodes;
};

helper fetch_today_stats => sub {
  my ($c, $tasks) = @_;
  my $done = 0;
  my $total = scalar(@$tasks);
  my $points = 0;

  for my $task (@$tasks) {
    if ($task->{done_today}) {
      $done++;
      $points += $task->{points} || 0;
    }
  }

  my $dbh = $c->db;
  my $dates = $dbh->selectcol_arrayref(
    q{
      SELECT DISTINCT log_date
      FROM task_logs
      WHERE status = 'done'
      ORDER BY log_date DESC
    }
  );

  my $streak = 0;
  my $day = localtime;
  for my $d (@$dates) {
    my $target = $day->ymd;
    last if $d ne $target;
    $streak++;
    $day -= ONE_DAY;
  }

  return {
    done => $done,
    total => $total,
    points => $points,
    progress_pct => $total ? int(($done / $total) * 100) : 0,
    streak => $streak,
  };
};

helper ai_suggestions => sub {
  my ($c, $prompt) = @_;
  $prompt //= '';

  my @suggestions;
  if ($prompt =~ /英語|English|TOEIC/i) {
    @suggestions = (
      {
        task => '英語ニュース記事を読む',
        duration_min => 15,
        priority => 'medium',
        description => '短い記事を1本読んで要点をメモ',
      },
      {
        task => '単語カード10枚復習',
        duration_min => 10,
        priority => 'low',
        description => '5分で前回の分を確認',
      },
    );
  } elsif ($prompt =~ /体力|運動|スポーツ|健康/i) {
    @suggestions = (
      {
        task => 'ランニング10分',
        duration_min => 10,
        priority => 'medium',
        description => '軽いペースでOK',
      },
      {
        task => 'ストレッチ5分',
        duration_min => 5,
        priority => 'low',
        description => '肩まわり中心に',
      },
    );
  } else {
    @suggestions = (
      {
        task => '小さな一歩を決める',
        duration_min => 10,
        priority => 'medium',
        description => '最初の10分だけ取り組む',
      },
      {
        task => '関連資料を1つ探す',
        duration_min => 15,
        priority => 'low',
        description => '記事や動画を1本',
      },
    );
  }

  return [
    map {
      my $title = $_->{task};
      {
        %$_,
        card_ui => {
          title => $title,
          subtitle => "所要時間: $_->{duration_min}分 / 優先度: $_->{priority}",
          add_button_label => '今日のやることに追加',
        },
      }
    } @suggestions
  ];
};

helper ollama_suggestions => sub {
  my ($c, $prompt) = @_;
  $prompt //= '';
  $prompt =~ s/^\s+|\s+$//g;
  return [] if $prompt eq '';

  my $ua = Mojo::UserAgent->new;
  $ua->request_timeout(20);

  my $system = <<'SYS';
You are a task breakdown assistant. Provide a JSON array of 3-6 actionable tasks.
Each item must have: task, duration_min (5-30), priority (high|medium|low), description.
Be practical and concrete. No extra text outside JSON.
SYS

  my $body = {
    model => 'qwen2.5:3b-instruct',
    stream => Mojo::JSON->false,
    format => 'json',
    prompt => $prompt,
    system => $system,
  };

  my $tx = $ua->post('http://localhost:11434/api/generate' => json => $body);
  my $res = $tx->result;
  return [] unless $res->is_success;

  my $payload = $res->json || {};
  my $text = $payload->{response} // '';
  $text =~ s/^\s+|\s+$//g;
  return [] if $text eq '';

  my $data;
  eval { $data = decode_json($text); 1 } or do {
    if ($text =~ /(\[.*\])/s) {
      eval { $data = decode_json($1); 1 };
    }
  };

  return [] unless ref $data eq 'ARRAY';

  my @out;
  for my $item (@$data) {
    next unless ref $item eq 'HASH';
    my $task = $item->{task} // '';
    my $duration = $item->{duration_min} // 10;
    my $priority = $item->{priority} // 'medium';
    my $desc = $item->{description} // '';
    next if $task eq '';
    push @out, {
      task => $task,
      duration_min => $duration + 0,
      priority => $priority,
      description => $desc,
      card_ui => {
        title => $task,
        subtitle => "所要時間: ${duration}分 / 優先度: $priority",
        add_button_label => '今日のやることに追加',
      },
    };
  }

  return \@out;
};

helper save_ai_message => sub {
  my ($c, $role, $content) = @_;
  return if !defined $content || $content eq '';
  $c->db->do(
    'INSERT INTO ai_messages (role, content) VALUES (?, ?)',
    undef,
    $role,
    $content
  );
};

helper fetch_ai_messages => sub {
  my $c = shift;
  return $c->db->selectall_arrayref(
    'SELECT role, content, created_at FROM ai_messages ORDER BY id ASC LIMIT 200',
    { Slice => {} }
  );
};

helper save_ai_pending => sub {
  my ($c, $goal_id, $suggestions) = @_;
  my $json = encode_json($suggestions || []);
  $c->db->do(
    'INSERT INTO ai_pending (goal_id, suggestions_json) VALUES (?, ?)',
    undef,
    $goal_id,
    $json
  );
};

helper fetch_latest_ai_pending => sub {
  my $c = shift;
  my $row = $c->db->selectrow_hashref(
    'SELECT id, goal_id, suggestions_json FROM ai_pending ORDER BY id DESC LIMIT 1'
  );
  return unless $row;
  my $data = eval { decode_json($row->{suggestions_json}) } || [];
  return { id => $row->{id}, goal_id => $row->{goal_id}, suggestions => $data };
};

helper clear_ai_pending => sub {
  my ($c, $id) = @_;
  $c->db->do('DELETE FROM ai_pending WHERE id = ?', undef, $id);
};

helper ai_chat_reply => sub {
  my ($c, $prompt) = @_;
  $prompt //= '';
  $prompt =~ s/^\s+|\s+$//g;
  return { text => 'まずは目標や状況を教えてください。', suggestions => [] } if $prompt eq '';

  my $ua = Mojo::UserAgent->new;
  $ua->request_timeout(20);

  my $system = <<'SYS';
You are a task breakdown assistant for a personal goal app.
Return ONLY JSON with:
{
  "summary": "short assistant reply",
  "subgoals": [{"title":"..."}],
  "tasks": [{"title":"...","duration_min":15,"priority":"high|medium|low","repeat_type":"none|daily|weekly","description":"..."}]
}
Keep 2-5 subgoals and 2-6 tasks. Be practical. No extra text outside JSON.
SYS

  my $body = {
    model => 'qwen2.5:3b-instruct',
    stream => Mojo::JSON->false,
    format => 'json',
    prompt => $prompt,
    system => $system,
  };

  my $tx = $ua->post('http://localhost:11434/api/generate' => json => $body);
  my $res = $tx->result;
  return { text => 'AIに接続できませんでした。もう一度試してください。', suggestions => [] }
    unless $res->is_success;

  my $payload = $res->json || {};
  my $text = $payload->{response} // '';
  $text =~ s/^\s+|\s+$//g;
  my $data;
  eval { $data = decode_json($text); 1 } or do {
    if ($text =~ /(\{.*\})/s) { eval { $data = decode_json($1); 1 }; }
  };

  return { text => 'うまく提案を生成できませんでした。もう一度試してください。', suggestions => [] }
    unless ref $data eq 'HASH';

  my $summary = $data->{summary} // 'この内容で提案します。追加してよいですか？（はい / いいえ）';
  my $subgoals = ref $data->{subgoals} eq 'ARRAY' ? $data->{subgoals} : [];
  my $tasks = ref $data->{tasks} eq 'ARRAY' ? $data->{tasks} : [];

  return {
    text => $summary . " 追加してよいですか？（はい / いいえ）",
    suggestions => { subgoals => $subgoals, tasks => $tasks },
  };
};

helper normalize_ai_suggestions => sub {
  my ($c, $ai) = @_;
  return [] unless $ai;

  if (ref $ai eq 'ARRAY') {
    return $ai if @$ai && ref $ai->[0] eq 'HASH';
    # Handle flat key/value list
    my @list = @$ai;
    my @out;
    my %cur;
    while (@list) {
      my ($k, $v) = splice(@list, 0, 2);
      if ($k eq 'task' && %cur && exists $cur{task}) {
        push @out, { %cur };
        %cur = ();
      }
      $cur{$k} = $v;
    }
    push @out, { %cur } if %cur;
    return \@out;
  }

  return [ $ai ] if ref $ai eq 'HASH';
  return [];
};

helper fetch_sticker_status => sub {
  my $c = shift;
  my $dbh = $c->db;
  my $today = _today_str();

  my $rows = $dbh->selectall_arrayref(
    q{
      SELECT
        t.id,
        t.title,
        (SELECT status FROM task_logs WHERE task_id = t.id AND log_date = ? ORDER BY created_at DESC LIMIT 1) AS today_status,
        (SELECT 1 FROM event_logs WHERE event_type = 'physical_obtained' AND target_type = 'task' AND target_id = t.id LIMIT 1) AS physical_obtained,
        (SELECT 1 FROM event_logs WHERE event_type = 'parent_checked' AND target_type = 'task' AND target_id = t.id LIMIT 1) AS parent_checked
      FROM tasks t
      WHERE t.active = 1
      ORDER BY t.id
    },
    { Slice => {} },
    $today
  );

  my @stickers;
  my $points = 0;
  for my $row (@$rows) {
    my $digital = ($row->{today_status} // '') eq 'done' ? 1 : 0;
    $points++ if $digital;
    push @stickers, {
      task => $row->{title},
      task_id => $row->{id},
      digital_obtained => $digital ? \1 : \0,
      physical_obtained => $row->{physical_obtained} ? \1 : \0,
      parent_checked => $row->{parent_checked} ? \1 : \0,
    };
  }

  return {
    stickers => \@stickers,
    total_points => $points,
    consecutive_days => $c->fetch_today_stats($c->fetch_tasks_today)->{streak},
  };
};

helper fetch_logs => sub {
  my $c = shift;
  my $dbh = $c->db;

  my $task_logs = $dbh->selectall_arrayref(
    q{
      SELECT created_at AS timestamp,
             CASE status WHEN 'done' THEN 'タスク完了' ELSE 'タスク未完了' END AS action,
             (SELECT title FROM tasks WHERE id = task_id) AS task
      FROM task_logs
      ORDER BY created_at DESC
      LIMIT 50
    },
    { Slice => {} }
  );

  my $event_logs = $dbh->selectall_arrayref(
    q{
      SELECT created_at AS timestamp,
             event_type AS action,
             CASE target_type WHEN 'task' THEN (SELECT title FROM tasks WHERE id = target_id) ELSE NULL END AS task
      FROM event_logs
      ORDER BY created_at DESC
      LIMIT 50
    },
    { Slice => {} }
  );

  my @combined = sort { $b->{timestamp} cmp $a->{timestamp} } (@$task_logs, @$event_logs);
  splice(@combined, 50) if @combined > 50;

  return \@combined;
};

sub _prepare_stash {
  my ($c, $opts) = @_;
  $opts ||= {};
  $c->ensure_db;

  my $tasks = $c->fetch_tasks_today;
  my $stats = $c->fetch_today_stats($tasks);
  my $goal_tree = $c->fetch_goal_tree;
  my $goal_options = $c->fetch_goal_options;
  my $status_map = $c->fetch_latest_task_status;
  $c->compute_progress_for_tree($goal_tree, $status_map);
  my $stickers = $c->fetch_sticker_status;
  my $ai = [];

  $c->stash(
    tasks => $tasks,
    today => _today_str(),
    stats => $stats,
    goal_tree => $goal_tree,
    goal_options => $goal_options,
    stickers => $stickers,
    ai_suggestions => $ai,
  );

  if ($opts->{with_lists}) {
    $c->stash(
      goal_list => $c->fetch_goal_list({}),
      task_list => $c->fetch_task_list({ sort => 'created_at', dir => 'desc' }),
    );
  }

  if ($opts->{with_logs}) {
    $c->stash(
      logs => $c->fetch_logs,
      logs_filtered => $c->fetch_logs_filtered({ type => 'all' }),
    );
  }
}

get '/' => sub { shift->redirect_to('/today') };

get '/today' => sub {
  my $c = shift;
  _prepare_stash($c);
  $c->stash(active => 'today');
  $c->render(template => 'today');
};

get '/goals' => sub {
  my $c = shift;
  _prepare_stash($c, { with_lists => 1 });
  $c->stash(active => 'goals_list');
  $c->render(template => 'goals_list');
};

get '/goals/:id' => sub {
  my $c = shift;
  my $goal_id = $c->param('id');
  _prepare_stash($c);
  my $goal_tree = $c->fetch_goal_tree($goal_id);
  my $status_map = $c->fetch_latest_task_status;
  $c->compute_progress_for_tree($goal_tree, $status_map);
  $c->stash(goal_tree => $goal_tree, selected_goal_id => $goal_id, active => 'goals_tree');
  $c->render(template => 'goals_tree');
};

get '/stickers' => sub {
  my $c = shift;
  _prepare_stash($c);
  $c->stash(active => 'stickers');
  $c->render(template => 'stickers');
};

get '/ai' => sub {
  my $c = shift;
  _prepare_stash($c);
  $c->stash(active => 'ai');
  my $messages = $c->fetch_ai_messages;
  $c->stash(ai_messages => $messages);
  $c->render(template => 'ai');
};

get '/lists' => sub {
  my $c = shift;
  _prepare_stash($c, { with_lists => 1 });
  $c->stash(active => 'lists');
  $c->render(template => 'lists');
};

get '/logs' => sub {
  my $c = shift;
  _prepare_stash($c, { with_logs => 1 });
  $c->stash(active => 'logs');
  $c->render(template => 'logs');
};

get '/tasks' => sub {
  my $c = shift;
  _prepare_stash($c, { with_lists => 1 });
  $c->stash(active => 'tasks');
  $c->render(template => 'tasks');
};

get '/progress' => sub {
  my $c = shift;
  _prepare_stash($c);
  $c->stash(active => 'progress');
  $c->render(template => 'progress');
};

post '/tasks/:id/toggle' => sub {
  my $c = shift;
  $c->ensure_db;

  my $task_id = $c->param('id');
  my $today = _today_str();
  my $dbh = $c->db;

  my ($status) = $dbh->selectrow_array(
    'SELECT status FROM task_logs WHERE task_id = ? AND log_date = ? ORDER BY created_at DESC LIMIT 1',
    undef,
    $task_id,
    $today
  );

  my $new_status = ($status && $status eq 'done') ? 'undone' : 'done';

  $dbh->do(
    'INSERT INTO task_logs (task_id, log_date, status) VALUES (?, ?, ?)',
    undef,
    $task_id,
    $today,
    $new_status
  );

  $dbh->do(
    'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
    undef,
    "task_$new_status",
    'task',
    $task_id,
    '{"source":"ui"}'
  );

  my $task_row = $dbh->selectrow_hashref(
    q{
      SELECT
        t.id,
        t.title,
        t.repeat_type,
        t.points,
        t.duration_min,
        t.priority,
        (SELECT status FROM task_logs WHERE task_id = t.id AND log_date = ? ORDER BY created_at DESC LIMIT 1) AS today_status
      FROM tasks t
      WHERE t.id = ?
    },
    undef,
    $today,
    $task_id
  );

  $task_row->{done_today} = ($task_row->{today_status} // '') eq 'done' ? 1 : 0;

  $c->stash(task => $task_row);
  $c->render(template => 'partials/task');
};

post '/stickers/:id/physical' => sub {
  my $c = shift;
  $c->ensure_db;
  my $task_id = $c->param('id');

  my ($exists) = $c->db->selectrow_array(
    'SELECT 1 FROM event_logs WHERE event_type = ? AND target_type = ? AND target_id = ? LIMIT 1',
    undef,
    'physical_obtained',
    'task',
    $task_id
  );
  if (!$exists) {
    $c->db->do(
      'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
      undef,
      'physical_obtained',
      'task',
      $task_id,
      '{"source":"ui"}'
    );
  }

  $c->redirect_to('/');
};

post '/stickers/:id/parent' => sub {
  my $c = shift;
  $c->ensure_db;
  my $task_id = $c->param('id');

  my ($exists) = $c->db->selectrow_array(
    'SELECT 1 FROM event_logs WHERE event_type = ? AND target_type = ? AND target_id = ? LIMIT 1',
    undef,
    'parent_checked',
    'task',
    $task_id
  );
  if (!$exists) {
    $c->db->do(
      'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
      undef,
      'parent_checked',
      'task',
      $task_id,
      '{"source":"ui"}'
    );
  }

  $c->redirect_to('/');
};

post '/ai/add' => sub {
  my $c = shift;
  $c->ensure_db;

  my $title = $c->param('title') // 'AIタスク';
  my $duration = $c->param('duration_min') // 15;
  my $priority = $c->param('priority') // 'medium';

  my ($goal_id) = $c->db->selectrow_array('SELECT id FROM goals WHERE parent_id IS NULL ORDER BY id LIMIT 1');
  $goal_id //= 1;

  $c->db->do(
    'INSERT INTO tasks (goal_id, title, repeat_type, duration_min, priority) VALUES (?, ?, ?, ?, ?)',
    undef,
    $goal_id,
    $title,
    'none',
    $duration,
    $priority
  );
  my $task_id = $c->db->sqlite_last_insert_rowid;

  $c->db->do(
    'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
    undef,
    'ai_task_added',
    'task',
    $task_id,
    '{"source":"ai"}'
  );

  if ($c->req->headers->header('HX-Request')) {
    my $tasks = $c->fetch_tasks_today;
    $c->stash(tasks => $tasks);
    return $c->render(template => 'partials/task_list');
  }

  $c->redirect_to('/');
};

post '/goals' => sub {
  my $c = shift;
  $c->ensure_db;

  my $title = $c->param('title') // '';
  my $deadline = $c->param('deadline');
  $title =~ s/^\s+|\s+$//g;

  if ($title ne '') {
    $c->db->do(
      'INSERT INTO goals (title, deadline, sort_order) VALUES (?, ?, ?)',
      undef,
      $title,
      $deadline,
      0
    );
    my $goal_id = $c->db->sqlite_last_insert_rowid;
    $c->db->do(
      'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
      undef,
      'goal_created',
      'goal',
      $goal_id,
      '{"source":"ui"}'
    );
  }

  my $redirect = $c->param('redirect') || '/goals';
  $c->redirect_to($redirect);
};

post '/goals/:id/subgoal' => sub {
  my $c = shift;
  $c->ensure_db;

  my $parent_id = $c->param('id');
  my $title = $c->param('title') // '';
  $title =~ s/^\s+|\s+$//g;

  if ($title ne '') {
    $c->db->do(
      'INSERT INTO goals (parent_id, title, sort_order) VALUES (?, ?, ?)',
      undef,
      $parent_id,
      $title,
      0
    );
    my $goal_id = $c->db->sqlite_last_insert_rowid;
    $c->db->do(
      'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
      undef,
      'goal_created',
      'goal',
      $goal_id,
      '{"source":"ui"}'
    );
  }

  if ($c->req->headers->header('HX-Request')) {
    my $goal_tree = $c->fetch_goal_tree;
    my $status_map = $c->fetch_latest_task_status;
    $c->compute_progress_for_tree($goal_tree, $status_map);
    $c->stash(goal_tree => $goal_tree);
    return $c->render(template => 'partials/goal_tree_cards_wrapper');
  }

  my $redirect = $c->param('redirect') || '/goals';
  $c->redirect_to($redirect);
};

post '/goals/:id/update' => sub {
  my $c = shift;
  $c->ensure_db;

  my $goal_id = $c->param('id');
  my $title = $c->param('title') // '';
  my $deadline = $c->param('deadline');
  $title =~ s/^\s+|\s+$//g;

  if ($title ne '') {
    $c->db->do(
      "UPDATE goals SET title = ?, deadline = ?, updated_at = datetime('now') WHERE id = ?",
      undef,
      $title,
      $deadline,
      $goal_id
    );
    $c->db->do(
      'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
      undef,
      'goal_updated',
      'goal',
      $goal_id,
      '{"source":"ui"}'
    );
  }

  if ($c->req->headers->header('HX-Request')) {
    my $goal_tree = $c->fetch_goal_tree;
    my $status_map = $c->fetch_latest_task_status;
    $c->compute_progress_for_tree($goal_tree, $status_map);
    $c->stash(goal_tree => $goal_tree);
    return $c->render(template => 'partials/goal_tree_cards_wrapper');
  }

  my $redirect = $c->param('redirect') || '/';
  $c->redirect_to($redirect);
};

post '/goals/:id/archive' => sub {
  my $c = shift;
  $c->ensure_db;

  my $goal_id = $c->param('id');

  if (!$c->goal_has_children($goal_id) && !$c->goal_has_tasks($goal_id)) {
    $c->db->do(
      "UPDATE goals SET archived = 1, updated_at = datetime('now') WHERE id = ?",
      undef,
      $goal_id
    );
    $c->db->do(
      'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
      undef,
      'goal_archived',
      'goal',
      $goal_id,
      '{"source":"ui"}'
    );
  }

  if ($c->req->headers->header('HX-Request')) {
    my $goal_tree = $c->fetch_goal_tree;
    my $status_map = $c->fetch_latest_task_status;
    $c->compute_progress_for_tree($goal_tree, $status_map);
    $c->stash(goal_tree => $goal_tree);
    return $c->render(template => 'partials/goal_tree_cards_wrapper');
  }

  my $redirect = $c->param('redirect') || '/';
  $c->redirect_to($redirect);
};

post '/goals/:id/archive_tree' => sub {
  my $c = shift;
  $c->ensure_db;

  my $goal_id = $c->param('id');
  $c->archive_goal_tree($goal_id);

  my $redirect = $c->param('redirect') || '/goals';
  $c->redirect_to($redirect);
};

post '/goals/:id/toggle_done' => sub {
  my $c = shift;
  $c->ensure_db;

  my $goal_id = $c->param('id');
  my ($current) = $c->db->selectrow_array('SELECT completed FROM goals WHERE id = ?', undef, $goal_id);
  my $new = ($current && $current == 1) ? 0 : 1;
  $c->db->do(
    "UPDATE goals SET completed = ?, updated_at = datetime('now') WHERE id = ?",
    undef,
    $new,
    $goal_id
  );
  $c->db->do(
    'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
    undef,
    $new ? 'goal_completed' : 'goal_uncompleted',
    'goal',
    $goal_id,
    '{"source":"ui"}'
  );

  my $redirect = $c->param('redirect') || '/goals';
  $c->redirect_to($redirect);
};

post '/goals/:id/task' => sub {
  my $c = shift;
  $c->ensure_db;

  my $goal_id = $c->param('id');
  my $title = $c->param('title') // '';
  my $duration = $c->param('duration_min') // 15;
  my $priority = $c->param('priority') // 'medium';
  $title =~ s/^\s+|\s+$//g;

  if ($title ne '') {
    $c->db->do(
      'INSERT INTO tasks (goal_id, title, repeat_type, duration_min, priority) VALUES (?, ?, ?, ?, ?)',
      undef,
      $goal_id,
      $title,
      'none',
      $duration,
      $priority
    );
    my $task_id = $c->db->sqlite_last_insert_rowid;
    $c->db->do(
      'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
      undef,
      'task_created',
      'task',
      $task_id,
      '{"source":"ui"}'
    );
  }

  if ($c->req->headers->header('HX-Request')) {
    my $tasks = $c->fetch_tasks_today;
    $c->stash(tasks => $tasks);
    return $c->render(template => 'partials/task_list');
  }

  my $redirect = $c->param('redirect') || '/tasks';
  $c->redirect_to($redirect);
};

post '/tasks/:id/update' => sub {
  my $c = shift;
  $c->ensure_db;

  my $task_id = $c->param('id');
  my $title = $c->param('title') // '';
  my $duration = $c->param('duration_min') // 15;
  my $priority = $c->param('priority') // 'medium';
  my $repeat_type = $c->param('repeat_type') // 'none';
  $title =~ s/^\s+|\s+$//g;

  if ($title ne '') {
    $c->db->do(
      "UPDATE tasks SET title = ?, duration_min = ?, priority = ?, repeat_type = ?, updated_at = datetime('now') WHERE id = ?",
      undef,
      $title,
      $duration,
      $priority,
      $repeat_type,
      $task_id
    );
    $c->db->do(
      'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
      undef,
      'task_updated',
      'task',
      $task_id,
      '{"source":"ui"}'
    );
  }

  if ($c->req->headers->header('HX-Request')) {
    my $tasks = $c->fetch_tasks_today;
    $c->stash(tasks => $tasks);
    return $c->render(template => 'partials/task_list');
  }

  $c->redirect_to('/');
};

post '/tasks/:id/archive' => sub {
  my $c = shift;
  $c->ensure_db;

  my $task_id = $c->param('id');
  $c->db->do(
    "UPDATE tasks SET active = 0, updated_at = datetime('now') WHERE id = ?",
    undef,
    $task_id
  );
  $c->db->do(
    'INSERT INTO event_logs (event_type, target_type, target_id, payload_json) VALUES (?, ?, ?, ?)',
    undef,
    'task_archived',
    'task',
    $task_id,
    '{"source":"ui"}'
  );

  if ($c->req->headers->header('HX-Request')) {
    my $tasks = $c->fetch_tasks_today;
    $c->stash(tasks => $tasks);
    return $c->render(template => 'partials/task_list');
  }

  $c->redirect_to('/');
};

post '/ai/suggest' => sub {
  my $c = shift;
  $c->ensure_db;

  my $prompt = $c->param('prompt') // '';
  my $suggestions = $c->ollama_suggestions($prompt);
  if (!@$suggestions) {
    $suggestions = $c->normalize_ai_suggestions($c->ai_suggestions($prompt));
  }
  $c->stash(ai_suggestions => $suggestions);
  $c->render(template => 'partials/ai_suggestions');
};

post '/ai/chat' => sub {
  my $c = shift;
  $c->ensure_db;

  my $goal_id = $c->param('goal_id');
  my $message = $c->param('message') // '';
  $message =~ s/^\s+|\s+$//g;

  if ($message ne '') {
    $c->save_ai_message('user', $message);
  }

  my $pending = $c->fetch_latest_ai_pending;
  if ($message =~ /^(はい|ok|yes|やる|お願い)/i && $pending) {
    my $gid = $pending->{goal_id} || $goal_id;
    my $sug = $pending->{suggestions} || {};
    for my $sg (@{ $sug->{subgoals} || [] }) {
      next unless $sg->{title};
      $c->db->do('INSERT INTO goals (parent_id, title, sort_order) VALUES (?, ?, ?)', undef, $gid, $sg->{title}, 0);
    }
    for my $t (@{ $sug->{tasks} || [] }) {
      next unless $t->{title};
      $c->db->do(
        'INSERT INTO tasks (goal_id, title, repeat_type, duration_min, priority) VALUES (?, ?, ?, ?, ?)',
        undef,
        $gid,
        $t->{title},
        ($t->{repeat_type} || 'none'),
        ($t->{duration_min} || 15),
        ($t->{priority} || 'medium')
      );
    }
    $c->clear_ai_pending($pending->{id});
    $c->save_ai_message('assistant', '追加しました。次に分解したいことはありますか？');
  } elsif ($message ne '') {
    my $reply = $c->ai_chat_reply($message);
    if ($reply->{suggestions} && ( @{ $reply->{suggestions}{subgoals} || [] } || @{ $reply->{suggestions}{tasks} || [] } )) {
      $c->save_ai_pending($goal_id, $reply->{suggestions});
    }
    $c->save_ai_message('assistant', $reply->{text});
  }

  my $messages = $c->fetch_ai_messages;
  $c->stash(ai_messages => $messages);
  $c->render(template => 'partials/ai_chat');
};

get '/partials/goal_tree' => sub {
  my $c = shift;
  $c->ensure_db;

  my $goal_tree = $c->fetch_goal_tree;
  my $status_map = $c->fetch_latest_task_status;
  $c->compute_progress_for_tree($goal_tree, $status_map);
  $c->stash(goal_tree => $goal_tree);
  $c->render(template => 'partials/goal_tree_cards_wrapper');
};

get '/partials/task_list' => sub {
  my $c = shift;
  $c->ensure_db;
  my $tasks = $c->fetch_tasks_today;
  $c->stash(tasks => $tasks);
  $c->render(template => 'partials/task_list');
};

get '/partials/goal_list' => sub {
  my $c = shift;
  $c->ensure_db;

  my $list = $c->fetch_goal_list({
    q => $c->param('q'),
    sort => $c->param('sort'),
    dir => $c->param('dir'),
  });
  $c->stash(goal_list => $list);
  $c->render(template => 'partials/goal_list');
};

get '/partials/task_list_table' => sub {
  my $c = shift;
  $c->ensure_db;

  my $list = $c->fetch_task_list({
    q => $c->param('q'),
    priority => $c->param('priority') || 'all',
    repeat => $c->param('repeat') || 'all',
    sort => $c->param('sort'),
    dir => $c->param('dir'),
    include_archived => $c->param('include_archived') ? 1 : 0,
  });
  $c->stash(task_list => $list);
  $c->render(template => 'partials/task_list_table');
};

get '/logs/filter' => sub {
  my $c = shift;
  $c->ensure_db;

  my $list = $c->fetch_logs_filtered({
    from => $c->param('from'),
    to => $c->param('to'),
    type => $c->param('type') || 'all',
  });
  $c->stash(logs_filtered => $list);
  $c->render(template => 'partials/logs_filtered');
};

get '/api/today' => sub {
  my $c = shift;
  $c->ensure_db;
  my $tasks = $c->fetch_tasks_today;
  my $stats = $c->fetch_today_stats($tasks);

  $c->render(json => {
    title => '今日のやること',
    tasks => [
      map {
        {
          task => $_->{title},
          duration_min => $_->{duration_min},
          priority => $_->{priority},
          completed => $_->{done_today} ? \1 : \0,
          points => $_->{points},
        }
      } @$tasks
    ],
    progress => "$stats->{done}/$stats->{total}完了",
  });
};

get '/api/goal_tree' => sub {
  my $c = shift;
  $c->ensure_db;
  my $goal_tree = $c->fetch_goal_tree;
  my $status_map = $c->fetch_latest_task_status;
  $c->compute_progress_for_tree($goal_tree, $status_map);

  my $root = $goal_tree->[0] // {};

  my $to_json;
  $to_json = sub {
    my ($node) = @_;
    return {
      name => $node->{title},
      progress => $node->{progress} || 0,
      tasks => [ map { { task => $_->{title}, completed => ($status_map->{$_->{id}} // '') eq 'done' ? \1 : \0 } } @{ $node->{tasks} || [] } ],
      subgoals => [ map { $to_json->($_) } @{ $node->{children} || [] } ],
    };
  };

  $c->render(json => {
    goal => $root->{title} // '未設定',
    progress => $root->{progress} || 0,
    subgoals => [ map { $to_json->($_) } @{ $root->{children} || [] } ],
  });
};

get '/api/ai_suggestions' => sub {
  my $c = shift;
  $c->ensure_db;
  my $prompt = $c->param('prompt') // '';
  my $suggestions = $c->ollama_suggestions($prompt);
  if (!@$suggestions) {
    $suggestions = $c->normalize_ai_suggestions($c->ai_suggestions($prompt));
  }
  $c->render(json => $suggestions);
};

get '/api/stickers' => sub {
  my $c = shift;
  $c->ensure_db;
  $c->render(json => $c->fetch_sticker_status);
};

get '/api/logs' => sub {
  my $c = shift;
  $c->ensure_db;
  $c->render(json => { logs => $c->fetch_logs });
};

get '/api/progress' => sub {
  my $c = shift;
  $c->ensure_db;
  my $goal_tree = $c->fetch_goal_tree;
  my $status_map = $c->fetch_latest_task_status;
  $c->compute_progress_for_tree($goal_tree, $status_map);

  my $root = $goal_tree->[0] // {};
  my @subs = map { { name => $_->{title}, progress => $_->{progress} || 0 } } @{ $root->{children} || [] };

  $c->render(json => {
    goal => $root->{title} // '未設定',
    progress => $root->{progress} || 0,
    subgoals => \@subs,
  });
};

app->start;
