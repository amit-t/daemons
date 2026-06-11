/* Devin ACU Burn Dashboard — renders window.DAG_DASHBOARD_DATA (dashboard-data.js).
   Static, dependency-free; data values are inserted via textContent only. */
(function () {
  'use strict';

  var data = window.DAG_DASHBOARD_DATA;
  if (!data) {
    document.getElementById('meta').textContent =
      'dashboard-data.js missing or empty — regenerate with: dag dashboard';
    return;
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function fmt(n) {
    if (n === null || n === undefined) return '—';
    return Number(n).toLocaleString('en-US', { maximumFractionDigits: 2 });
  }

  document.getElementById('meta').textContent =
    'Generated ' + data.generated_at +
    ' · Cycle ' + data.cycle.start_date + ' → ' + data.cycle.end_date +
    ' · Day ' + data.cycle.elapsed_days + ' of ' + data.cycle.cycle_days +
    ' (' + data.cycle.left_days + ' left)';

  var refresh = data.refresh || {};
  var refreshMeta = document.getElementById('refresh-meta');
  if (refresh.enabled && refresh.interval_ms > 0) {
    refreshMeta.textContent =
      'Auto-refresh every ' + refresh.interval_minutes +
      ' minute(s). Keep the matching dag dashboard --refresh command running.';
    window.setTimeout(function () {
      window.location.reload();
    }, refresh.interval_ms);
  } else {
    refreshMeta.textContent = 'Static snapshot. Use dag dashboard --refresh <5|10|15|30> for auto-refresh.';
  }

  // Headline cards.
  var ent = data.enterprise;
  var cards = [
    ['Consumed ACUs', fmt(ent.consumed), ''],
    ['Remaining of ' + fmt(data.pool), fmt(ent.remaining), ent.remaining < 0 ? 'bad' : ''],
    ['Daily run rate', fmt(ent.daily_run_rate), ''],
    ['Projected cycle-end', fmt(ent.projected_cycle_total), ''],
    ['Verdict', ent.verdict, ent.verdict === 'OVER' ? 'bad' : 'good']
  ];
  var cardsEl = document.getElementById('cards');
  cards.forEach(function (c) {
    var d = el('div', ('card ' + c[2]).trim());
    d.appendChild(el('div', 'card-label', c[0]));
    d.appendChild(el('div', 'card-value', c[1]));
    cardsEl.appendChild(d);
  });

  // Daily burn — plain SVG bar chart.
  var daily = data.daily || [];
  var chart = document.getElementById('daily-chart');
  if (daily.length === 0) {
    chart.appendChild(el('p', 'empty', 'No daily consumption recorded this cycle.'));
  } else {
    var NS = 'http://www.w3.org/2000/svg';
    var W = 840, H = 240, pad = 30;
    var peak = Math.max.apply(null, daily.map(function (d) { return d.acus; }));
    var max = peak || 1;
    var svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    svg.setAttribute('role', 'img');
    var bw = (W - pad * 2) / daily.length;
    daily.forEach(function (d, i) {
      var h = (d.acus / max) * (H - pad * 2);
      var r = document.createElementNS(NS, 'rect');
      r.setAttribute('x', (pad + i * bw + 1).toFixed(2));
      r.setAttribute('y', (H - pad - h).toFixed(2));
      r.setAttribute('width', Math.max(1, bw - 2).toFixed(2));
      r.setAttribute('height', Math.max(0.5, h).toFixed(2));
      r.setAttribute('class', 'bar');
      var t = document.createElementNS(NS, 'title');
      t.textContent = d.date + ': ' + fmt(d.acus) + ' ACUs (devin ' + fmt(d.devin) +
        ', cascade ' + fmt(d.cascade) + ', terminal ' + fmt(d.terminal) +
        ', review ' + fmt(d.review) + ')';
      r.appendChild(t);
      svg.appendChild(r);
    });
    [[daily[0].date, pad, 'start'], [daily[daily.length - 1].date, W - pad, 'end']]
      .forEach(function (lab) {
        var tx = document.createElementNS(NS, 'text');
        tx.setAttribute('x', lab[1]);
        tx.setAttribute('y', H - 8);
        tx.setAttribute('text-anchor', lab[2]);
        tx.setAttribute('class', 'axis-label');
        tx.textContent = lab[0];
        svg.appendChild(tx);
      });
    var maxLab = document.createElementNS(NS, 'text');
    maxLab.setAttribute('x', pad);
    maxLab.setAttribute('y', 16);
    maxLab.setAttribute('class', 'axis-label');
    maxLab.textContent = 'peak ' + fmt(peak) + ' ACUs/day';
    svg.appendChild(maxLab);
    chart.appendChild(svg);
  }

  // Product split bars.
  var split = data.product_split || [];
  var smax = Math.max.apply(null, split.map(function (p) { return p.acus; })) || 1;
  var splitEl = document.getElementById('product-split');
  split.forEach(function (p) {
    var row = el('div', 'split-row');
    row.appendChild(el('span', 'split-label', p.product));
    var track = el('div', 'split-track');
    var bar = el('div', 'split-bar split-' + p.product);
    bar.style.width = (p.acus / smax * 100).toFixed(1) + '%';
    track.appendChild(bar);
    row.appendChild(track);
    row.appendChild(el('span', 'split-value', fmt(p.acus) + ' ACUs'));
    splitEl.appendChild(row);
  });

  // Org table.
  var tbody = document.querySelector('#org-table tbody');
  (data.orgs || []).forEach(function (o) {
    var tr = document.createElement('tr');
    tr.appendChild(el('td', '', o.name));
    [o.consumed, o.daily_run_rate, o.projected, o.max_cycle_acu_limit, o.max_session_acu_limit]
      .forEach(function (v) { tr.appendChild(el('td', 'num', fmt(v))); });
    tr.appendChild(el('td', 'num',
      o.pct_limit === null || o.pct_limit === undefined ? '—' : (o.pct_limit * 100).toFixed(1) + '%'));
    var td = el('td');
    td.appendChild(el('span', 'badge badge-' + o.status, o.status));
    tr.appendChild(td);
    tbody.appendChild(tr);
  });

  // User table.
  var userTbody = document.querySelector('#user-table tbody');
  (data.users || []).forEach(function (u) {
    var tr = document.createElement('tr');
    tr.appendChild(el('td', '', u.name || '—'));
    tr.appendChild(el('td', '', u.email || '—'));
    [u.consumed, u.effective_cycle_acu_limit, u.headroom]
      .forEach(function (v) { tr.appendChild(el('td', 'num', fmt(v))); });
    tr.appendChild(el('td', 'num',
      u.pct_limit === null || u.pct_limit === undefined ? '—' : (u.pct_limit * 100).toFixed(1) + '%'));
    tr.appendChild(el('td', '', u.cap_source || '—'));
    tr.appendChild(el('td', '', u.billing_org_id || '—'));
    var td = el('td');
    td.appendChild(el('span', 'badge badge-' + u.status, u.status));
    tr.appendChild(td);
    userTbody.appendChild(tr);
  });

  // Warnings panel.
  var warnings = data.warnings || [];
  var ul = document.getElementById('warnings');
  if (warnings.length === 0) {
    ul.appendChild(el('li', 'empty', 'None — every org within cap and forecast.'));
  } else {
    warnings.forEach(function (w) { ul.appendChild(el('li', '', w)); });
  }
})();
