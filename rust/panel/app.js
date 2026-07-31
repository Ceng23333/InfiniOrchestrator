const state = {
  snapshot: null,
  activeTab: "dashboard",
  autoRefresh: true,
  playgroundMode: "fresh",
  filters: {
    search: "",
    health: "all",
    host: "all",
    bench: "all",
    model: "all",
  },
};

const els = {};

document.addEventListener("DOMContentLoaded", () => {
  bindElements();
  bindEvents();
  loadSnapshot();
  window.setInterval(() => {
    if (state.autoRefresh) {
      loadSnapshot({ quiet: true });
    }
  }, 15000);
});

function bindElements() {
  Object.assign(els, {
    status: document.querySelector("#snapshot-status"),
    refreshButton: document.querySelector("#refresh-button"),
    autoRefresh: document.querySelector("#auto-refresh"),
    tabs: Array.from(document.querySelectorAll(".tab")),
    views: Array.from(document.querySelectorAll(".view")),
    serverSearch: document.querySelector("#server-search"),
    healthFilter: document.querySelector("#health-filter"),
    hostFilter: document.querySelector("#host-filter"),
    metrics: document.querySelector("#dashboard-metrics"),
    metricTemplate: document.querySelector("#metric-template"),
    clusterLabel: document.querySelector("#cluster-label"),
    topologyMap: document.querySelector("#topology-map"),
    routerHealth: document.querySelector("#router-health"),
    routerDetails: document.querySelector("#router-details"),
    serverCount: document.querySelector("#server-count"),
    serverTable: document.querySelector("#server-table"),
    benchFilter: document.querySelector("#bench-filter"),
    modelFilter: document.querySelector("#model-filter"),
    dateFilter: document.querySelector("#date-filter"),
    benchCount: document.querySelector("#bench-count"),
    benchCatalog: document.querySelector("#bench-catalog"),
    resultCount: document.querySelector("#result-count"),
    benchmarkResults: document.querySelector("#benchmark-results"),
    playgroundMode: document.querySelector("#playground-mode"),
    segments: Array.from(document.querySelectorAll(".segment")),
    playgroundForm: document.querySelector("#playground-form"),
    pgCluster: document.querySelector("#pg-cluster"),
    pgHost: document.querySelector("#pg-host"),
    pgTraffic: document.querySelector("#pg-traffic"),
    pgModel: document.querySelector("#pg-model"),
    pgTemplate: document.querySelector("#pg-template"),
    pgForkSource: document.querySelector("#pg-fork-source"),
    pgBench: document.querySelector("#pg-bench"),
    pgConcurrency: document.querySelector("#pg-concurrency"),
    pgPrompts: document.querySelector("#pg-prompts"),
    launchPlan: document.querySelector("#launch-plan"),
    copyPlan: document.querySelector("#copy-plan"),
  });
}

function bindEvents() {
  els.refreshButton.addEventListener("click", () => loadSnapshot());
  els.autoRefresh.addEventListener("change", (event) => {
    state.autoRefresh = event.target.checked;
  });

  els.tabs.forEach((tab) => {
    tab.addEventListener("click", () => setActiveTab(tab.dataset.tab));
  });

  els.serverSearch.addEventListener("input", (event) => {
    state.filters.search = event.target.value.trim().toLowerCase();
    renderDashboard();
  });
  els.healthFilter.addEventListener("change", (event) => {
    state.filters.health = event.target.value;
    renderDashboard();
  });
  els.hostFilter.addEventListener("change", (event) => {
    state.filters.host = event.target.value;
    renderDashboard();
  });
  els.benchFilter.addEventListener("change", (event) => {
    state.filters.bench = event.target.value;
    renderBenchmark();
  });
  els.modelFilter.addEventListener("change", (event) => {
    state.filters.model = event.target.value;
    renderBenchmark();
  });
  els.dateFilter.addEventListener("change", renderBenchmark);

  els.segments.forEach((segment) => {
    segment.addEventListener("click", () => {
      state.playgroundMode = segment.dataset.mode;
      els.segments.forEach((item) =>
        item.classList.toggle("is-active", item === segment),
      );
      renderPlayground();
    });
  });

  els.playgroundForm.addEventListener("input", renderLaunchPlan);
  els.playgroundForm.addEventListener("change", renderLaunchPlan);
  els.copyPlan.addEventListener("click", async () => {
    await copyText(els.launchPlan.textContent);
    els.copyPlan.textContent = "Copied";
    window.setTimeout(() => {
      els.copyPlan.textContent = "Copy";
    }, 1200);
  });
}

async function loadSnapshot(options = {}) {
  if (!options.quiet) {
    setStatus("Loading", "neutral");
  }

  try {
    const response = await fetch("/panel/api/snapshot", {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    state.snapshot = await response.json();
    setStatus("Live", "ok");
    hydrateControls();
    renderAll();
  } catch (error) {
    console.error(error);
    setStatus("Offline", "bad");
    renderError(error);
  }
}

function setStatus(text, tone) {
  els.status.textContent = text;
  els.status.classList.toggle("is-ok", tone === "ok");
  els.status.classList.toggle("is-bad", tone === "bad");
}

function setActiveTab(tabName) {
  state.activeTab = tabName;
  els.tabs.forEach((tab) => {
    tab.classList.toggle("is-active", tab.dataset.tab === tabName);
  });
  els.views.forEach((view) => {
    view.classList.toggle("is-active", view.id === tabName);
  });
}

function renderAll() {
  renderDashboard();
  renderBenchmark();
  renderPlayground();
}

function hydrateControls() {
  const snapshot = state.snapshot;
  const hosts = snapshot.hosts || [];
  const benches = snapshot.benches || [];
  const models = getModelIds(snapshot);

  setOptions(els.hostFilter, [
    ["all", "All hosts"],
    ...hosts.map((host) => [host.host_id, host.hostname || host.host_id]),
  ]);
  setOptions(els.benchFilter, [
    ["all", "All benches"],
    ...benches.map((bench) => [bench.bench_id, bench.bench_id]),
  ]);
  setOptions(els.modelFilter, [
    ["all", "All models"],
    ...models.map((model) => [model, model]),
  ]);
  setOptions(
    els.pgHost,
    hosts.length ? hosts.map((host) => [host.host_id, host.hostname || host.host_id]) : [["", "default"]],
  );
  setOptions(
    els.pgModel,
    models.length ? models.map((model) => [model, model]) : [["", "default"]],
  );
  setOptions(
    els.pgForkSource,
    (snapshot.servers || []).length
      ? (snapshot.servers || []).map((server) => [
          server.server_id,
          server.service_name || server.server_id,
        ])
      : [["", "none"]],
  );
  setOptions(
    els.pgBench,
    benches.map((bench) => [bench.bench_id, bench.bench_id]),
  );
  els.pgCluster.value = snapshot.cluster?.cluster_id || "default";
}

function setOptions(select, options) {
  const previous = select.value;
  select.replaceChildren(
    ...options.map(([value, label]) => {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = label;
      return option;
    }),
  );

  if (options.some(([value]) => value === previous)) {
    select.value = previous;
  }
}

function renderDashboard() {
  const snapshot = state.snapshot;
  if (!snapshot) {
    return;
  }

  const servers = getFilteredServers();
  const allServers = snapshot.servers || [];
  const healthy = allServers.filter((server) => server.healthy).length;
  const errors = allServers.reduce((sum, server) => sum + number(server.error_count), 0);
  const requests = allServers.reduce((sum, server) => sum + number(server.request_count), 0);

  renderMetrics([
    ["Services", allServers.length, `${healthy} healthy`],
    ["Hosts", (snapshot.hosts || []).length, snapshot.cluster?.env || "env unset"],
    ["Models", getModelIds(snapshot).length, "aggregated"],
    ["Traffic", compactNumber(requests), `${compactNumber(errors)} errors`],
  ]);

  els.clusterLabel.textContent = [
    snapshot.cluster?.name,
    snapshot.cluster?.registry_url,
  ]
    .filter(Boolean)
    .join(" | ");
  renderTopology(snapshot, servers);
  renderRouter(snapshot);
  renderServerTable(servers);
}

function renderMetrics(metrics) {
  els.metrics.replaceChildren(
    ...metrics.map(([label, value, sub]) => {
      const tile = els.metricTemplate.content.firstElementChild.cloneNode(true);
      tile.querySelector(".metric-label").textContent = label;
      tile.querySelector(".metric-value").textContent = value;
      tile.querySelector(".metric-sub").textContent = sub;
      return tile;
    }),
  );
}

function renderTopology(snapshot, servers) {
  const cluster = snapshot.cluster || {};
  const router = (snapshot.routers || [])[0] || {};
  const hosts = snapshot.hosts || [];

  const clusterNode = topologyNode("Cluster", cluster.name || cluster.cluster_id || "default", [
    ["Hosts", hosts.length],
    ["Env", cluster.env || "unknown"],
  ]);
  const routerNode = topologyNode(
    "Router",
    router.router_id || "router-local",
    [
      ["Policy", router.lb_policy || "weighted_round_robin"],
      ["Services", router.stats_snapshot?.total_services || 0],
    ],
    "router",
  );
  const serverNode = document.createElement("div");
  serverNode.className = "topology-node servers";
  serverNode.innerHTML = `
    <div class="node-title"><span>Servers</span><span>${servers.length}</span></div>
    <div class="node-stack"></div>
  `;
  const stack = serverNode.querySelector(".node-stack");
  stack.replaceChildren(
    ...servers.slice(0, 7).map((server) => {
      const item = document.createElement("span");
      item.className = `server-chip${server.healthy ? "" : " is-bad"}`;
      item.textContent = server.service_name || server.server_id;
      item.title = item.textContent;
      return item;
    }),
  );
  if (servers.length > 7) {
    const more = document.createElement("span");
    more.className = "server-chip";
    more.textContent = `+${servers.length - 7} more`;
    stack.append(more);
  }

  els.topologyMap.replaceChildren(clusterNode, routerNode, serverNode);
}

function topologyNode(label, value, rows, tone = "") {
  const node = document.createElement("div");
  node.className = `topology-node ${tone}`.trim();
  node.innerHTML = `
    <div class="node-title"><span>${escapeHtml(label)}</span></div>
    <div class="node-value">${escapeHtml(value)}</div>
    <dl class="key-values"></dl>
  `;
  const dl = node.querySelector("dl");
  dl.replaceChildren(
    ...rows.flatMap(([key, item]) => [
      element("dt", key),
      element("dd", String(item)),
    ]),
  );
  return node;
}

function renderRouter(snapshot) {
  const router = (snapshot.routers || [])[0] || {};
  const stats = router.stats_snapshot || {};
  const healthy = Boolean(router.healthy);
  els.routerHealth.textContent = healthy ? "Healthy" : "Unhealthy";
  els.routerHealth.classList.toggle("is-ok", healthy);
  els.routerHealth.classList.toggle("is-bad", !healthy);

  const models = (router.models || [])
    .map((model) => model.id || model)
    .filter(Boolean);
  const rows = [
    ["Router ID", router.router_id || "router-local"],
    ["URL", router.url || window.location.origin],
    ["Registry", snapshot.cluster?.registry_url || "not configured"],
    ["Healthy services", `${stats.healthy_services || 0}/${stats.total_services || 0}`],
    ["Models", models.length ? models.join(", ") : "none"],
  ];
  els.routerDetails.replaceChildren(
    ...rows.flatMap(([key, value]) => [element("dt", key), element("dd", value)]),
  );
}

function renderServerTable(servers) {
  els.serverCount.textContent = `${servers.length} shown`;

  if (!servers.length) {
    const row = document.createElement("tr");
    row.innerHTML = `<td colspan="8">No services match the active filters.</td>`;
    els.serverTable.replaceChildren(row);
    return;
  }

  els.serverTable.replaceChildren(
    ...servers.map((server) => {
      const row = document.createElement("tr");
      row.innerHTML = `
        <td><strong>${escapeHtml(server.service_name || server.server_id)}</strong></td>
        <td>${escapeHtml(server.host_id || "")}</td>
        <td>${renderModelChips(server.models || server.model || [])}</td>
        <td><span class="status-text${server.healthy ? "" : " is-bad"}">${escapeHtml(server.status || "unknown")}</span></td>
        <td>${number(server.weight)}</td>
        <td>${compactNumber(server.request_count)}</td>
        <td>${compactNumber(server.error_count)}</td>
        <td>${formatLatency(server.response_time)}</td>
      `;
      return row;
    }),
  );
}

function getFilteredServers() {
  const snapshot = state.snapshot;
  if (!snapshot) {
    return [];
  }

  return (snapshot.servers || []).filter((server) => {
    const text = [
      server.service_name,
      server.server_id,
      server.host_id,
      server.url,
      ...(server.models || []),
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    const healthMatch =
      state.filters.health === "all" ||
      (state.filters.health === "healthy" && server.healthy) ||
      (state.filters.health === "unhealthy" && !server.healthy);
    const hostMatch =
      state.filters.host === "all" || server.host_id === state.filters.host;
    const searchMatch = !state.filters.search || text.includes(state.filters.search);
    return healthMatch && hostMatch && searchMatch;
  });
}

function renderBenchmark() {
  const snapshot = state.snapshot;
  if (!snapshot) {
    return;
  }

  const benches = (snapshot.benches || []).filter((bench) => {
    return state.filters.bench === "all" || bench.bench_id === state.filters.bench;
  });
  els.benchCount.textContent = `${benches.length} benches`;
  els.benchCatalog.replaceChildren(...benches.map(renderBenchCatalogItem));

  const results = (snapshot.bench_results || []).filter((result) => {
    const benchMatch =
      state.filters.bench === "all" || result.bench_id === state.filters.bench;
    const modelMatch =
      state.filters.model === "all" || result.model === state.filters.model;
    return benchMatch && modelMatch;
  });
  els.resultCount.textContent = `${results.length} rows`;
  if (!results.length) {
    els.benchmarkResults.textContent =
      snapshot.source_status?.benchmark || "No BenchResult rows available.";
  } else {
    els.benchmarkResults.replaceChildren(renderResultsTable(results));
  }
}

function renderBenchCatalogItem(bench) {
  const item = document.createElement("article");
  item.className = "catalog-item";
  const defaults = Object.entries(bench.default_params || {})
    .map(([key, value]) => `${key}=${value}`)
    .join(", ");
  item.innerHTML = `
    <div>
      <p class="catalog-title">${escapeHtml(bench.bench_id)}</p>
      <p class="catalog-meta">${escapeHtml(bench.runner || "")}</p>
    </div>
    <span class="model-chip">${escapeHtml(bench.bench_family || bench.source || "")}</span>
  `;
  item.title = defaults;
  return item;
}

function renderResultsTable(results) {
  const wrap = document.createElement("div");
  wrap.className = "table-wrap";
  wrap.innerHTML = `
    <table>
      <thead>
        <tr>
          <th>Bench</th>
          <th>Server</th>
          <th>Model</th>
          <th>Status</th>
          <th>Started</th>
        </tr>
      </thead>
      <tbody></tbody>
    </table>
  `;
  wrap.querySelector("tbody").replaceChildren(
    ...results.map((result) => {
      const row = document.createElement("tr");
      row.innerHTML = `
        <td>${escapeHtml(result.bench_id || "")}</td>
        <td>${escapeHtml(result.server_id || "")}</td>
        <td>${escapeHtml(result.model || "")}</td>
        <td>${escapeHtml(result.status || "")}</td>
        <td>${escapeHtml(result.started_at || "")}</td>
      `;
      return row;
    }),
  );
  return wrap;
}

function renderPlayground() {
  if (!state.snapshot) {
    return;
  }
  els.playgroundMode.textContent = state.playgroundMode === "fresh" ? "Fresh" : "Fork";
  els.pgForkSource.disabled = state.playgroundMode !== "fork";
  renderLaunchPlan();
}

function renderLaunchPlan() {
  const snapshot = state.snapshot || {};
  const router = (snapshot.routers || [])[0] || {};
  const traffic = els.pgTraffic.value;
  const plan = {
    mode: state.playgroundMode,
    cluster_id: els.pgCluster.value || snapshot.cluster?.cluster_id || "default",
    host_id: els.pgHost.value || null,
    router_id: traffic === "router" ? router.router_id || "router-local" : null,
    server: {
      template: els.pgTemplate.value,
      model: els.pgModel.value || null,
      forked_from_server_id: state.playgroundMode === "fork" ? selectedForkSource() : null,
    },
    bench: {
      bench_id: els.pgBench.value || null,
      bench_args: {
        MAX_CONCURRENCY: number(els.pgConcurrency.value),
        NUM_PROMPTS: number(els.pgPrompts.value),
        ROUTER_URL: traffic === "router" ? router.url || window.location.origin : null,
        BENCH_TARGET_URL: traffic === "direct" ? "<server-url>" : null,
      },
    },
    control_plane_status: snapshot.source_status?.playground || "not configured",
  };

  els.launchPlan.textContent = JSON.stringify(plan, null, 2);
}

function selectedForkSource() {
  return els.pgForkSource.value || null;
}

async function copyText(text) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.left = "-9999px";
  document.body.append(textarea);
  textarea.select();
  document.execCommand("copy");
  textarea.remove();
}

function renderError(error) {
  els.metrics.replaceChildren();
  els.topologyMap.textContent = "";
  els.routerDetails.replaceChildren(
    element("dt", "Error"),
    element("dd", error.message || String(error)),
  );
  els.serverTable.replaceChildren();
  els.benchmarkResults.textContent = "Snapshot unavailable.";
  els.launchPlan.textContent = "{}";
}

function getModelIds(snapshot) {
  const fromRouter = (snapshot.routers || []).flatMap((router) =>
    (router.models || []).map((model) => model.id || model),
  );
  const fromServers = (snapshot.servers || []).flatMap((server) => server.models || []);
  return Array.from(new Set([...fromRouter, ...fromServers].filter(Boolean))).sort();
}

function renderModelChips(models) {
  const list = Array.isArray(models) ? models : [models].filter(Boolean);
  if (!list.length) {
    return '<span class="muted">none</span>';
  }
  return list
    .slice(0, 3)
    .map((model) => `<span class="model-chip" title="${escapeAttr(model)}">${escapeHtml(model)}</span>`)
    .join(" ");
}

function element(tag, text) {
  const node = document.createElement(tag);
  node.textContent = text;
  return node;
}

function number(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function compactNumber(value) {
  return new Intl.NumberFormat("en", { notation: "compact" }).format(number(value));
}

function formatLatency(value) {
  const numeric = number(value);
  if (!numeric) {
    return "0 ms";
  }
  return `${numeric.toFixed(1)} ms`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("`", "&#096;");
}
