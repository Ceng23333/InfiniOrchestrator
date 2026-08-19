// Harness viz plugins register on window.HarnessVizPlugins[suiteId] from cases/<id>/panel/viz.js.
// Contract: enrichRows, mountToolbar, filterRow, tableColumns, numericColumns, statusLine, defaultPluginFilters.

const state = {
  snapshot: null,
  harness: null,
  playgroundCases: null,
  harnessCases: null,
  activeTab: "playground",
  autoRefresh: true,
  highlightedRowId: null,
  selectedPlaygroundCaseId: null,
  selectedHarnessSuiteId: null,
  filters: {
    search: "",
    health: "all",
    host: "all",
  },
  playground: {
    search: "",
    category: "all",
    model: "all",
    hw: "all",
    be: "all",
  },
  harnessBrowser: {
    search: "",
    family: "all",
    runnable: "all",
  },
  viz: {
    category: "harness",
    harness: "",
    model: "all",
    deployMode: "all",
    hardware: "all",
    backend: "all",
    dateFrom: "",
    dateTo: "",
    metric: "",
  },
  vizPlugin: null,
  vizPluginFilters: {},
  vizPluginScriptEl: null,
  vizSort: { key: "date", dir: "desc" },
};

const SERIES_COLORS = [
  "#1769aa",
  "#087d8f",
  "#7158b8",
  "#14845c",
  "#b7791f",
  "#c2413a",
  "#0f4e82",
];

const ITW_GITHUB_TREE_BASE =
  "https://github.com/Ceng23333/InfiniTensorWorktree/tree";

const els = {};

const PANEL_TABS = ["playground", "harness", "visualization", "dashboard"];

document.addEventListener("DOMContentLoaded", () => {
  bindElements();
  bindEvents();
  setActiveTab(tabFromLocation(), { fromLocation: true });
  loadSnapshot();
  loadPlaygroundCases();
  loadHarnessCases();
  window.setInterval(() => {
    if (state.autoRefresh) {
      loadSnapshot({ quiet: true });
      if (state.activeTab === "visualization") {
        loadHarnessData({ quiet: true });
      }
      if (state.activeTab === "playground") {
        loadPlaygroundCases({ quiet: true });
      }
      if (state.activeTab === "harness") {
        loadHarnessCases({ quiet: true });
      }
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
    grafanaLink: document.querySelector("#grafana-link"),
    grafanaNote: document.querySelector("#grafana-note"),
    metrics: document.querySelector("#dashboard-metrics"),
    metricTemplate: document.querySelector("#metric-template"),
    clusterLabel: document.querySelector("#cluster-label"),
    topologyMap: document.querySelector("#topology-map"),
    routerHealth: document.querySelector("#router-health"),
    routerDetails: document.querySelector("#router-details"),
    serverCount: document.querySelector("#server-count"),
    serverTable: document.querySelector("#server-table"),
    pgSearch: document.querySelector("#pg-search"),
    pgCategory: document.querySelector("#pg-category"),
    pgModel: document.querySelector("#pg-model"),
    pgHw: document.querySelector("#pg-hw"),
    pgBe: document.querySelector("#pg-be"),
    pgSourceStatus: document.querySelector("#pg-source-status"),
    pgCaseCount: document.querySelector("#pg-case-count"),
    pgCaseList: document.querySelector("#pg-case-list"),
    pgCaseDetail: document.querySelector("#pg-case-detail"),
    hnSearch: document.querySelector("#hn-search"),
    hnFamily: document.querySelector("#hn-family"),
    hnRunnable: document.querySelector("#hn-runnable"),
    hnSourceStatus: document.querySelector("#hn-source-status"),
    hnCaseCount: document.querySelector("#hn-case-count"),
    hnCaseList: document.querySelector("#hn-case-list"),
    hnCaseDetail: document.querySelector("#hn-case-detail"),
    vizCategory: document.querySelector("#viz-category"),
    vizHarness: document.querySelector("#viz-harness"),
    vizModel: document.querySelector("#viz-model"),
    vizDeployMode: document.querySelector("#viz-deploy-mode"),
    vizHardware: document.querySelector("#viz-hardware"),
    vizBackend: document.querySelector("#viz-backend"),
    vizDateFrom: document.querySelector("#viz-date-from"),
    vizDateTo: document.querySelector("#viz-date-to"),
    vizCaseToolbar: document.querySelector("#viz-case-toolbar"),
    vizMetric: document.querySelector("#viz-metric"),
    vizSourceStatus: document.querySelector("#viz-source-status"),
    vizChart: document.querySelector("#viz-chart"),
    vizChartMeta: document.querySelector("#viz-chart-meta"),
    vizLegend: document.querySelector("#viz-legend"),
    vizRowCount: document.querySelector("#viz-row-count"),
    vizTable: document.querySelector("#viz-table"),
  });
}

function bindEvents() {
  els.refreshButton.addEventListener("click", () => {
    loadSnapshot();
    loadPlaygroundCases();
    loadHarnessCases();
    if (state.activeTab === "visualization") {
      loadHarnessData();
    }
  });
  els.autoRefresh.addEventListener("change", (event) => {
    state.autoRefresh = event.target.checked;
  });

  els.tabs.forEach((tab) => {
    tab.addEventListener("click", () => setActiveTab(tab.dataset.tab));
  });
  window.addEventListener("hashchange", () => {
    setActiveTab(tabFromLocation(), { fromLocation: true });
  });

  const vizControls = [
    [els.vizCategory, "category"],
    [els.vizHarness, "harness"],
    [els.vizModel, "model"],
    [els.vizDeployMode, "deployMode"],
    [els.vizHardware, "hardware"],
    [els.vizBackend, "backend"],
    [els.vizMetric, "metric"],
  ];
  vizControls.forEach(([el, key]) => {
    if (!el) {
      return;
    }
    el.addEventListener("change", (event) => {
      state.viz[key] = event.target.value;
      if (key === "harness") {
        loadHarnessData();
      } else {
        renderVisualization();
      }
    });
  });
  els.vizDateFrom.addEventListener("change", (event) => {
    state.viz.dateFrom = event.target.value;
    renderVisualization();
  });
  els.vizDateTo.addEventListener("change", (event) => {
    state.viz.dateTo = event.target.value;
    renderVisualization();
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

  els.pgSearch.addEventListener("input", (event) => {
    state.playground.search = event.target.value.trim().toLowerCase();
    renderPlayground();
  });
  els.pgCategory.addEventListener("change", (event) => {
    state.playground.category = event.target.value;
    renderPlayground();
  });
  els.pgModel.addEventListener("change", (event) => {
    state.playground.model = event.target.value;
    renderPlayground();
  });
  els.pgHw.addEventListener("change", (event) => {
    state.playground.hw = event.target.value;
    renderPlayground();
  });
  els.pgBe.addEventListener("change", (event) => {
    state.playground.be = event.target.value;
    renderPlayground();
  });

  els.hnSearch.addEventListener("input", (event) => {
    state.harnessBrowser.search = event.target.value.trim().toLowerCase();
    renderHarnessBrowser();
  });
  els.hnFamily.addEventListener("change", (event) => {
    state.harnessBrowser.family = event.target.value;
    renderHarnessBrowser();
  });
  els.hnRunnable.addEventListener("change", (event) => {
    state.harnessBrowser.runnable = event.target.value;
    renderHarnessBrowser();
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

function tabFromLocation() {
  const raw = (window.location.hash || "").replace(/^#/, "").trim();
  const tab = raw.split(/[/?&]/)[0];
  return PANEL_TABS.includes(tab) ? tab : "playground";
}

function setActiveTab(tabName, options = {}) {
  const nextTab = PANEL_TABS.includes(tabName) ? tabName : "playground";
  state.activeTab = nextTab;
  els.tabs.forEach((tab) => {
    tab.classList.toggle("is-active", tab.dataset.tab === nextTab);
  });
  els.views.forEach((view) => {
    view.classList.toggle("is-active", view.id === nextTab);
  });
  if (!options.fromLocation) {
    const nextHash = `#${nextTab}`;
    if (window.location.hash !== nextHash) {
      history.replaceState(null, "", nextHash);
    }
  }
  if (nextTab === "visualization") {
    if (!state.harnessCases) {
      loadHarnessCases().then(() => {
        if (state.viz.harness) {
          loadHarnessData();
        }
      });
    } else if (state.viz.harness && !state.harness) {
      loadHarnessData();
    }
  }
  if (nextTab === "playground" && !state.playgroundCases) {
    loadPlaygroundCases();
  }
  if (nextTab === "harness" && !state.harnessCases) {
    loadHarnessCases();
  }
}

function renderAll() {
  renderDashboard();
  renderPlayground();
  renderHarnessBrowser();
  renderVisualization();
}

async function loadPlaygroundCases(options = {}) {
  if (!els.pgCaseList) {
    return;
  }
  if (!options.quiet) {
    els.pgCaseList.className = "empty-state";
    els.pgCaseList.textContent = "Loading playground cases…";
  }
  try {
    const response = await fetch("/panel/api/cases/playground", {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    state.playgroundCases = await response.json();
    hydratePlaygroundControls();
    renderPlayground();
  } catch (error) {
    console.error(error);
    state.playgroundCases = null;
    els.pgSourceStatus.textContent = `Failed to load cases: ${error.message || error}`;
    els.pgCaseList.className = "empty-state";
    els.pgCaseList.textContent = "Playground cases unavailable.";
    els.pgCaseCount.textContent = "";
  }
}

async function loadHarnessCases(options = {}) {
  if (!els.hnCaseList) {
    return;
  }
  if (!options.quiet) {
    els.hnCaseList.className = "empty-state";
    els.hnCaseList.textContent = "Loading harness suites…";
  }
  try {
    const response = await fetch("/panel/api/cases/harness", {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    state.harnessCases = await response.json();
    hydrateHarnessControls();
    hydrateVizHarnessSelect();
    renderHarnessBrowser();
  } catch (error) {
    console.error(error);
    state.harnessCases = null;
    els.hnSourceStatus.textContent = `Failed to load suites: ${error.message || error}`;
    els.hnCaseList.className = "empty-state";
    els.hnCaseList.textContent = "Harness suites unavailable.";
    els.hnCaseCount.textContent = "";
  }
}

function getVizEnabledHarnesses() {
  return (state.harnessCases?.cases || []).filter((item) => item.viz?.enabled);
}

function hydrateVizHarnessSelect() {
  if (!els.vizHarness) {
    return;
  }
  const harnesses = getVizEnabledHarnesses();
  const options = harnesses.map((item) => [item.suite_id, item.viz?.title || item.suite_id]);
  if (!options.length) {
    setOptions(els.vizHarness, [["", "No viz-enabled harness"]]);
    state.viz.harness = "";
    return;
  }
  if (!options.some(([value]) => value === state.viz.harness)) {
    state.viz.harness = options[0][0];
  }
  setOptions(els.vizHarness, options);
  els.vizHarness.value = state.viz.harness;
}

function getVizPlugin() {
  const suiteId = state.viz.harness;
  if (!suiteId) {
    return null;
  }
  return window.HarnessVizPlugins?.[suiteId] || state.vizPlugin;
}

function resetVizPluginFilters(plugin) {
  if (plugin?.defaultPluginFilters) {
    state.vizPluginFilters = { ...plugin.defaultPluginFilters() };
  } else {
    state.vizPluginFilters = {};
  }
}

function unloadVizPlugin() {
  if (els.vizCaseToolbar) {
    els.vizCaseToolbar.replaceChildren();
  }
  if (state.vizPluginScriptEl) {
    state.vizPluginScriptEl.remove();
    state.vizPluginScriptEl = null;
  }
  state.vizPlugin = null;
}

async function loadVizPlugin(suiteId) {
  unloadVizPlugin();
  if (!suiteId) {
    return null;
  }
  const harnessCase = (state.harnessCases?.cases || []).find((item) => item.suite_id === suiteId);
  const assetsBase = (harnessCase?.viz?.assets || `/panel/harness-assets/${suiteId}/`).replace(/\/+$/, "");
  const scriptUrl = `${assetsBase}/viz.js`;

  await new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = scriptUrl;
    script.async = true;
    script.dataset.harnessViz = suiteId;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error(`failed to load viz plugin for ${suiteId}`));
    document.head.append(script);
    state.vizPluginScriptEl = script;
  });

  const plugin = window.HarnessVizPlugins?.[suiteId] || null;
  state.vizPlugin = plugin;
  resetVizPluginFilters(plugin);
  return plugin;
}

function enrichHarnessRows(rows) {
  const plugin = getVizPlugin();
  if (plugin?.enrichRows) {
    return plugin.enrichRows(rows);
  }
  return rows;
}

function mountVizPluginToolbar() {
  if (!els.vizCaseToolbar) {
    return;
  }
  els.vizCaseToolbar.replaceChildren();
  const plugin = getVizPlugin();
  if (!plugin?.mountToolbar) {
    return;
  }
  plugin.mountToolbar(els.vizCaseToolbar, {
    state,
    getFilters: () => ({ ...state.viz }),
    getPluginFilters: () => ({ ...state.vizPluginFilters }),
    setPluginFilter: (key, value) => {
      state.vizPluginFilters[key] = value;
    },
    rerender: () => renderVisualization(),
  });
}

async function loadHarnessData(options = {}) {
  if (!els.vizChart) {
    return;
  }
  const suiteId = state.viz.harness;
  if (!suiteId) {
    els.vizChart.className = "viz-chart empty-state";
    els.vizChart.textContent = "Select a harness with visualization enabled.";
    els.vizSourceStatus.textContent = "";
    els.vizLegend.replaceChildren();
    els.vizTable.className = "empty-state";
    els.vizTable.textContent = "Select a harness.";
    els.vizRowCount.textContent = "";
    return;
  }
  if (!options.quiet) {
    els.vizChart.className = "viz-chart empty-state";
    els.vizChart.textContent = "Loading harness data…";
  }

  try {
    await loadVizPlugin(suiteId);
    const response = await fetch(`/panel/api/harness/${encodeURIComponent(suiteId)}`, {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const payload = await response.json();
    payload.rows = enrichHarnessRows(payload.rows || []);
    state.harness = payload;
    const plugin = getVizPlugin();
    state.viz.metric =
      plugin?.defaultMetric || payload.default_metric || payload.metrics?.[0] || "";
    hydrateVizControls();
    mountVizPluginToolbar();
    renderVisualization();
  } catch (error) {
    console.error(error);
    state.harness = null;
    els.vizSourceStatus.textContent = `Failed to load harness data: ${error.message || error}`;
    els.vizChart.className = "viz-chart empty-state";
    els.vizChart.textContent = "Harness data unavailable.";
    els.vizLegend.replaceChildren();
    els.vizTable.className = "empty-state";
    els.vizTable.textContent = "Harness data unavailable.";
    els.vizRowCount.textContent = "";
  }
}

function hydratePlaygroundControls() {
  const cases = state.playgroundCases?.cases || [];
  const models = uniqueSorted(cases.map((item) => item.model_id));
  const hws = uniqueSorted(cases.map((item) => item.hw_abbr));
  const bes = uniqueSorted(cases.map((item) => item.be_abbr));
  setOptions(els.pgModel, [["all", "All"], ...models.map((value) => [value, value])]);
  setOptions(els.pgHw, [["all", "All"], ...hws.map((value) => [value, value])]);
  setOptions(els.pgBe, [["all", "All"], ...bes.map((value) => [value, value])]);
  els.pgModel.value = state.playground.model;
  els.pgHw.value = state.playground.hw;
  els.pgBe.value = state.playground.be;
  els.pgCategory.value = state.playground.category;
}

function hydrateHarnessControls() {
  const cases = state.harnessCases?.cases || [];
  const families = uniqueSorted(cases.map((item) => item.family));
  setOptions(els.hnFamily, [["all", "All"], ...families.map((value) => [value, value])]);
  els.hnFamily.value = state.harnessBrowser.family;
  els.hnRunnable.value = state.harnessBrowser.runnable;
}

function hydrateVizControls() {
  const harness = state.harness;
  if (!harness) {
    return;
  }
  const options = harness.filter_options || {};
  setOptions(els.vizModel, [
    ["all", "All"],
    ...(options.models || []).map((value) => [value, value]),
  ]);
  const deployModes = options.deploy_modes || ["Standalone", "Distribution"];
  setOptions(els.vizDeployMode, [
    ["all", "All"],
    ...deployModes.map((value) => [value, value]),
  ]);
  setOptions(els.vizHardware, [
    ["all", "All"],
    ...(options.hardware || []).map((value) => [value, value]),
  ]);
  setOptions(els.vizBackend, [
    ["all", "All"],
    ...(options.backends || []).map((value) => [value, value]),
  ]);
  const metrics = harness.metrics || ["total_tok_per_s"];
  setOptions(
    els.vizMetric,
    metrics.map((value) => [value, value]),
  );
  if (metrics.includes(state.viz.metric)) {
    els.vizMetric.value = state.viz.metric;
  } else {
    state.viz.metric = harness.default_metric || metrics[0];
    els.vizMetric.value = state.viz.metric;
  }
  els.vizModel.value = state.viz.model;
  els.vizDeployMode.value = state.viz.deployMode;
  els.vizHardware.value = state.viz.hardware;
  els.vizBackend.value = state.viz.backend;
  els.vizDateFrom.value = state.viz.dateFrom;
  els.vizDateTo.value = state.viz.dateTo;
}

function getFilteredHarnessRows() {
  const harness = state.harness;
  if (!harness) {
    return [];
  }
  const plugin = getVizPlugin();
  return (harness.rows || []).filter((row) => {
    const model = row.model || row.model_id || "";
    const deployMode = row.deploy_mode || row.case_category || "";
    const hardware = row.hw || "";
    const backend = row.be || "";
    const date = row.date || "";
    const modelMatch = state.viz.model === "all" || model === state.viz.model;
    const deployModeMatch =
      state.viz.deployMode === "all" || deployMode === state.viz.deployMode;
    const hardwareMatch =
      state.viz.hardware === "all" || hardware === state.viz.hardware;
    const backendMatch =
      state.viz.backend === "all" || backend === state.viz.backend;
    const fromMatch = !state.viz.dateFrom || date >= state.viz.dateFrom;
    const toMatch = !state.viz.dateTo || date <= state.viz.dateTo;
    if (
      !(
        modelMatch &&
        deployModeMatch &&
        hardwareMatch &&
        backendMatch &&
        fromMatch &&
        toMatch
      )
    ) {
      return false;
    }
    if (plugin?.filterRow) {
      return plugin.filterRow(row, state.viz, state.vizPluginFilters);
    }
    return true;
  });
}

function renderVisualization() {
  if (!els.vizChart) {
    return;
  }
  const harness = state.harness;
  if (!harness) {
    return;
  }

  const source = harness.source || {};
  const sourceLine =
    source.status === "ok"
      ? `Source: ${source.repo || ""} (${(source.files || []).length} files)`
      : `Source: ${source.status || "unavailable"}`;
  const sync = source.sync;
  let syncPart = "";
  if (sync && typeof sync === "object") {
    const bits = [];
    if (sync.status) {
      bits.push(String(sync.status));
    }
    if (sync.sha) {
      bits.push(String(sync.sha));
    }
    if (sync.pulled_at) {
      bits.push(String(sync.pulled_at));
    }
    if (bits.length) {
      syncPart = ` · sync ${bits.join(" ")}`;
    }
  }
  const plugin = getVizPlugin();
  const pluginStatus = plugin?.statusLine
    ? plugin.statusLine({ filters: state.viz, pluginFilters: state.vizPluginFilters })
    : "";
  els.vizSourceStatus.textContent = `${sourceLine}${syncPart}${pluginStatus}`;

  const rows = getFilteredHarnessRows();
  els.vizRowCount.textContent = `${rows.length} rows`;
  renderVizChart(rows);
  renderVizTable(sortHarnessRows(rows));
}

function isVizNumericColumn(key) {
  const plugin = getVizPlugin();
  const metric = state.viz.metric || "";
  if (plugin?.numericColumns) {
    const cols = plugin.numericColumns(metric);
    if (cols instanceof Set) {
      return cols.has(key);
    }
    if (Array.isArray(cols)) {
      return cols.includes(key);
    }
  }
  if (key && key === metric) {
    return true;
  }
  const metrics = state.harness?.metrics || [];
  return metrics.includes(key);
}

function sortHarnessRows(rows) {
  const key = state.vizSort?.key || "date";
  const dir = state.vizSort?.dir === "asc" ? "asc" : "desc";
  const numeric = isVizNumericColumn(key);
  const mult = dir === "asc" ? 1 : -1;
  return [...rows].sort((a, b) => {
    const av = a?.[key];
    const bv = b?.[key];
    if (numeric) {
      const an = Number(av);
      const bn = Number(bv);
      const aOk = Number.isFinite(an);
      const bOk = Number.isFinite(bn);
      if (!aOk && !bOk) {
        return 0;
      }
      if (!aOk) {
        return 1;
      }
      if (!bOk) {
        return -1;
      }
      if (an === bn) {
        return 0;
      }
      return an < bn ? -mult : mult;
    }
    const as = av == null || av === "" ? "" : String(av);
    const bs = bv == null || bv === "" ? "" : String(bv);
    if (!as && !bs) {
      return 0;
    }
    if (!as) {
      return 1;
    }
    if (!bs) {
      return -1;
    }
    return as.localeCompare(bs) * mult;
  });
}

function setVizSort(key) {
  if (!key) {
    return;
  }
  if (state.vizSort?.key === key) {
    state.vizSort.dir = state.vizSort.dir === "asc" ? "desc" : "asc";
  } else {
    state.vizSort = {
      key,
      dir: isVizNumericColumn(key) ? "desc" : "asc",
    };
  }
  renderVisualization();
}

function isInfiniLmBackend(be) {
  return String(be || "").toLowerCase() === "infinilm";
}

function seriesKey(row) {
  const model = row.model || row.model_id || "unknown";
  const hw = row.hw || "unknown";
  const be = row.be || "unknown";
  const preset = row.preset || "unknown";
  return `${model} · ${hw} · ${be} · ${preset}`;
}

function metricLowerIsBetter(metric) {
  return metric.startsWith("ttft_") || metric.startsWith("itl_") || metric.startsWith("tpot_") || metric.startsWith("srv_");
}

function isBetterMetric(candidate, incumbent, metric) {
  if (incumbent == null) {
    return true;
  }
  if (metricLowerIsBetter(metric)) {
    return candidate < incumbent;
  }
  return candidate > incumbent;
}

function renderVizChart(rows) {
  const metric = state.viz.metric || "total_tok_per_s";
  const rawPoints = rows
    .map((row) => {
      const y = Number(row[metric]);
      if (!Number.isFinite(y)) {
        return null;
      }
      const date = row.date || "";
      const ts = Date.parse(row.started_at || "") || Date.parse(`${date}T00:00:00Z`);
      if (!Number.isFinite(ts) || !date) {
        return null;
      }
      return {
        row,
        x: ts,
        y,
        date,
        series: seriesKey(row),
        rowId: row.row_id,
      };
    })
    .filter(Boolean);

  const bestBySeriesDate = new Map();
  rawPoints.forEach((point) => {
    const key = `${point.series}||${point.date}`;
    const existing = bestBySeriesDate.get(key);
    if (!existing || isBetterMetric(point.y, existing.y, metric)) {
      bestBySeriesDate.set(key, point);
    }
  });

  const points = Array.from(bestBySeriesDate.values()).sort((a, b) => a.x - b.x);

  if (!points.length) {
    els.vizChart.className = "viz-chart empty-state";
    els.vizChart.textContent =
      rows.length === 0
        ? "No rows match the active filters."
        : `No numeric ${metric} values in the filtered rows.`;
    els.vizChartMeta.textContent = metric;
    els.vizLegend.replaceChildren();
    return;
  }

  const seriesMap = new Map();
  points.forEach((point) => {
    if (!seriesMap.has(point.series)) {
      seriesMap.set(point.series, []);
    }
    seriesMap.get(point.series).push(point);
  });
  const seriesNames = Array.from(seriesMap.keys()).sort();

  const width = 920;
  const height = 320;
  const pad = { top: 20, right: 24, bottom: 42, left: 64 };
  const plotW = width - pad.left - pad.right;
  const plotH = height - pad.top - pad.bottom;
  const xs = points.map((p) => p.x);
  const ys = points.map((p) => p.y);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const xSpan = Math.max(maxX - minX, 1);
  const ySpan = Math.max(maxY - minY, Number.EPSILON);
  const xPos = (x) => pad.left + ((x - minX) / xSpan) * plotW;
  const yPos = (y) => pad.top + plotH - ((y - minY) / ySpan) * plotH;

  const yTicks = 4;
  let svg = `<svg viewBox="0 0 ${width} ${height}" class="viz-svg" role="img" aria-label="${escapeAttr(metric)} time series">`;
  svg += `<rect x="0" y="0" width="${width}" height="${height}" fill="transparent"></rect>`;
  for (let i = 0; i <= yTicks; i += 1) {
    const value = minY + (ySpan * i) / yTicks;
    const y = yPos(value);
    svg += `<line x1="${pad.left}" y1="${y}" x2="${width - pad.right}" y2="${y}" class="viz-grid"></line>`;
    svg += `<text x="${pad.left - 8}" y="${y + 4}" class="viz-axis" text-anchor="end">${escapeHtml(formatMetric(value))}</text>`;
  }
  svg += `<text x="${pad.left}" y="${height - 12}" class="viz-axis">${escapeHtml(formatChartTime(minX))}</text>`;
  svg += `<text x="${width - pad.right}" y="${height - 12}" class="viz-axis" text-anchor="end">${escapeHtml(formatChartTime(maxX))}</text>`;

  seriesNames.forEach((name, index) => {
    const color = SERIES_COLORS[index % SERIES_COLORS.length];
    const series = seriesMap.get(name).sort((a, b) => a.x - b.x);
    const path = series
      .map((point, idx) => `${idx === 0 ? "M" : "L"}${xPos(point.x)},${yPos(point.y)}`)
      .join(" ");
    svg += `<path d="${path}" fill="none" stroke="${color}" stroke-width="2"></path>`;
    series.forEach((point) => {
      svg += `<circle class="viz-dot" data-row-id="${escapeAttr(point.rowId)}" cx="${xPos(point.x)}" cy="${yPos(point.y)}" r="5" fill="${color}" stroke="#fff" stroke-width="1.5"><title>${escapeHtml(name)} · ${escapeHtml(formatMetric(point.y))} · ${escapeHtml(point.date)}</title></circle>`;
    });
  });
  svg += "</svg>";

  els.vizChart.className = "viz-chart";
  els.vizChart.innerHTML = svg;
  els.vizChartMeta.textContent = `${metric} · ${points.length} chart points (best/day) · ${seriesNames.length} series`;
  els.vizLegend.replaceChildren(
    ...seriesNames.map((name, index) => {
      const item = document.createElement("span");
      item.className = "viz-legend-item";
      item.innerHTML = `<i style="background:${SERIES_COLORS[index % SERIES_COLORS.length]}"></i>${escapeHtml(name)}`;
      return item;
    }),
  );

  els.vizChart.querySelectorAll(".viz-dot").forEach((dot) => {
    dot.addEventListener("click", () => {
      highlightVizRow(dot.getAttribute("data-row-id"));
    });
  });
}

function renderVizTable(rows) {
  if (!rows.length) {
    els.vizTable.className = "empty-state";
    els.vizTable.textContent = "No rows match the active filters.";
    return;
  }

  const metric = state.viz.metric || "total_tok_per_s";
  const plugin = getVizPlugin();
  const columns = plugin?.tableColumns
    ? [...plugin.tableColumns(metric)]
    : ["date", "model", "hw", "be", "worktree"];
  if (!columns.includes(metric)) {
    columns.push(metric);
  }
  columns.push("source");

  const sortKey = state.vizSort?.key || "date";
  const sortDir = state.vizSort?.dir === "asc" ? "asc" : "desc";
  const playgroundCaseIds = new Set(
    (state.playgroundCases?.cases || []).map((item) => item.case_id),
  );

  const wrap = document.createElement("div");
  wrap.className = "table-wrap";
  const table = document.createElement("table");
  table.className = "viz-table";
  const thead = document.createElement("thead");
  const headRow = document.createElement("tr");
  columns.forEach((col) => {
    const th = document.createElement("th");
    th.className = "sortable";
    const label = col === "source" ? "Source" : col;
    const isActive = sortKey === col;
    if (isActive) {
      th.classList.add(sortDir === "asc" ? "is-sorted-asc" : "is-sorted-desc");
      th.setAttribute("aria-sort", sortDir === "asc" ? "ascending" : "descending");
    } else {
      th.setAttribute("aria-sort", "none");
    }
    const button = document.createElement("button");
    button.type = "button";
    button.className = "viz-sort-btn";
    const marker = isActive ? (sortDir === "asc" ? " ↑" : " ↓") : "";
    button.textContent = `${label}${marker}`;
    button.addEventListener("click", () => setVizSort(col));
    th.append(button);
    headRow.append(th);
  });
  thead.append(headRow);
  const tbody = document.createElement("tbody");
  rows.forEach((row) => {
    const tr = document.createElement("tr");
    tr.dataset.rowId = row.row_id || "";
    if (state.highlightedRowId && state.highlightedRowId === row.row_id) {
      tr.classList.add("is-highlighted");
    }
    columns.forEach((col) => {
      const td = document.createElement("td");
      if (col === "source") {
        const path = row.tsv_path || "";
        const line = row.tsv_line || "";
        const label = path && line ? `${path}:${line}` : path || "—";
        const href = warehouseSourceUrl(path, line);
        if (href) {
          const link = document.createElement("a");
          link.className = "source-link";
          link.href = href;
          link.target = "_blank";
          link.rel = "noopener";
          link.title = href;
          link.textContent = label;
          td.append(link);
        } else {
          td.textContent = label;
        }
      } else if (col === "case_id") {
        const caseId = row.case_id != null ? String(row.case_id).trim() : "";
        if (caseId && playgroundCaseIds.has(caseId)) {
          const link = document.createElement("button");
          link.type = "button";
          link.className = "source-link case-link";
          link.textContent = caseId;
          link.addEventListener("click", () => navigateToPlaygroundCase(caseId));
          td.append(link);
        } else {
          td.textContent = caseId;
        }
      } else if (col === "worktree") {
        const tag = worktreeCellValue(row);
        if (tag && isInfiniLmBackend(row.be)) {
          const link = document.createElement("a");
          link.className = "source-link";
          link.href = `${ITW_GITHUB_TREE_BASE}/${encodeURIComponent(tag)}`;
          link.target = "_blank";
          link.rel = "noopener";
          link.title = link.href;
          link.textContent = tag;
          td.append(link);
        } else {
          td.textContent = tag;
        }
      } else if (isVizNumericColumn(col)) {
        td.textContent = formatMetric(row[col]);
      } else {
        td.textContent = row[col] != null ? row[col] : "";
      }
      tr.append(td);
    });
    tbody.append(tr);
  });
  table.append(thead, tbody);
  wrap.append(table);
  els.vizTable.className = "";
  els.vizTable.replaceChildren(wrap);
}

function worktreeCellValue(row) {
  const worktree = row.worktree != null ? String(row.worktree).trim() : "";
  if (worktree) {
    return worktree;
  }
  if (isInfiniLmBackend(row.be)) {
    return worktree;
  }
  return row.image_tag != null ? String(row.image_tag).trim() : "";
}

function navigateToPlaygroundCase(caseId) {
  if (!caseId) {
    return;
  }
  state.selectedPlaygroundCaseId = caseId;
  setActiveTab("playground");
  renderPlayground();
}

function warehouseSourceUrl(path, line) {
  if (!path) {
    return "";
  }
  const base = (state.harness?.source?.github_blob_base || "").replace(/\/$/, "");
  if (!base) {
    return "";
  }
  const cleaned = String(path).replace(/^\/+/, "");
  const anchor = line ? `#L${line}` : "";
  return `${base}/${cleaned}${anchor}`;
}

function highlightVizRow(rowId) {
  if (!rowId) {
    return;
  }
  state.highlightedRowId = rowId;
  const rows = els.vizTable.querySelectorAll("tr[data-row-id]");
  let target = null;
  rows.forEach((row) => {
    const match = row.dataset.rowId === rowId;
    row.classList.toggle("is-highlighted", match);
    if (match) {
      target = row;
    }
  });
  if (target) {
    target.scrollIntoView({ behavior: "smooth", block: "center" });
  }
}

function formatMetric(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return value == null ? "" : String(value);
  }
  if (Math.abs(numeric) >= 100 || Number.isInteger(numeric)) {
    return numeric.toFixed(Math.abs(numeric) >= 100 ? 1 : 0);
  }
  return numeric.toFixed(3);
}

function formatChartTime(ts) {
  try {
    return new Date(ts).toISOString().replace("T", " ").replace(/\.\d+Z$/, "Z");
  } catch (_error) {
    return String(ts);
  }
}

function hydrateControls() {
  const snapshot = state.snapshot;
  const hosts = snapshot.hosts || [];

  setOptions(els.hostFilter, [
    ["all", "All hosts"],
    ...hosts.map((host) => [host.host_id, host.hostname || host.host_id]),
  ]);
}

function setOptions(select, options) {
  if (!select) {
    return;
  }
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
  renderGrafanaLink(snapshot);
  renderTopology(snapshot, servers);
  renderRouter(snapshot);
  renderServerTable(servers);
}

function renderGrafanaLink(snapshot) {
  const url = (snapshot.grafana_url || "").trim();
  if (!url) {
    els.grafanaLink.href = "#";
    els.grafanaLink.classList.add("is-disabled");
    els.grafanaLink.setAttribute("aria-disabled", "true");
    els.grafanaNote.textContent = "GRAFANA_URL unset";
    return;
  }
  els.grafanaLink.href = url;
  els.grafanaLink.classList.remove("is-disabled");
  els.grafanaLink.removeAttribute("aria-disabled");
  els.grafanaNote.textContent = url;
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

function getFilteredPlaygroundCases() {
  const cases = state.playgroundCases?.cases || [];
  return cases.filter((item) => {
    const categoryMatch =
      state.playground.category === "all" || item.category === state.playground.category;
    const modelMatch =
      state.playground.model === "all" || item.model_id === state.playground.model;
    const hwMatch = state.playground.hw === "all" || item.hw_abbr === state.playground.hw;
    const beMatch = state.playground.be === "all" || item.be_abbr === state.playground.be;
    const text = [
      item.case_id,
      item.model_id,
      item.hw_abbr,
      item.be_abbr,
      item.worktree,
      item.case_path,
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    const searchMatch = !state.playground.search || text.includes(state.playground.search);
    return categoryMatch && modelMatch && hwMatch && beMatch && searchMatch;
  });
}

function renderPlayground() {
  if (!els.pgCaseList) {
    return;
  }
  const payload = state.playgroundCases;
  if (!payload) {
    return;
  }
  const source = payload.source || {};
  els.pgSourceStatus.textContent =
    source.status === "ok"
      ? `Source: ${source.root || ""}`
      : `Source: ${source.status || "unavailable"}`;

  const cases = getFilteredPlaygroundCases();
  els.pgCaseCount.textContent = `${cases.length} cases`;
  if (!cases.length) {
    els.pgCaseList.className = "empty-state";
    els.pgCaseList.textContent = "No playground cases match the filters.";
    els.pgCaseDetail.className = "empty-state";
    els.pgCaseDetail.textContent = "Select a case.";
    return;
  }

  const list = document.createElement("div");
  list.className = "catalog-list";
  list.replaceChildren(
    ...cases.map((item) => {
      const article = document.createElement("article");
      article.className = "catalog-item";
      if (state.selectedPlaygroundCaseId === item.case_id) {
        article.classList.add("is-selected");
      }
      article.innerHTML = `
        <div>
          <p class="catalog-title">${escapeHtml(item.case_id)}</p>
          <p class="catalog-meta">${escapeHtml(item.category)} · ${escapeHtml(item.model_id)} · ${escapeHtml(item.hw_abbr)}/${escapeHtml(item.be_abbr)}</p>
        </div>
        <span class="model-chip">${escapeHtml(item.worktree || "")}</span>
      `;
      if (item.github_dir_url) {
        const ghLink = document.createElement("a");
        ghLink.className = "source-link catalog-github";
        ghLink.href = item.github_dir_url;
        ghLink.target = "_blank";
        ghLink.rel = "noopener";
        ghLink.textContent = "GitHub";
        ghLink.title = item.github_dir_url;
        ghLink.addEventListener("click", (event) => event.stopPropagation());
        article.querySelector(".catalog-title")?.append(document.createTextNode(" "));
        article.querySelector(".catalog-title")?.append(ghLink);
      }
      article.addEventListener("click", () => {
        state.selectedPlaygroundCaseId = item.case_id;
        renderPlayground();
      });
      return article;
    }),
  );
  els.pgCaseList.className = "";
  els.pgCaseList.replaceChildren(list);

  const selected =
    cases.find((item) => item.case_id === state.selectedPlaygroundCaseId) || cases[0];
  state.selectedPlaygroundCaseId = selected.case_id;
  renderCaseDetail(els.pgCaseDetail, [
    ["case_id", selected.case_id],
    ["category", selected.category],
    ["n", selected.n],
    ["model_id", selected.model_id],
    ["hw_profile_id", selected.hw_profile_id],
    ["hw_abbr", selected.hw_abbr],
    ["be_abbr", selected.be_abbr],
    ["worktree", selected.worktree],
    ["case_path", selected.case_path],
    [
      "github",
      selected.github_dir_url
        ? { href: selected.github_dir_url, label: "Open case directory on GitHub" }
        : "",
    ],
    ["has_readme", selected.has_readme],
    ["has_compose", selected.has_compose],
  ]);
}

function getFilteredHarnessSuites() {
  const cases = state.harnessCases?.cases || [];
  return cases.filter((item) => {
    const familyMatch =
      state.harnessBrowser.family === "all" || item.family === state.harnessBrowser.family;
    const runnableMatch =
      state.harnessBrowser.runnable === "all" ||
      (state.harnessBrowser.runnable === "yes" && item.runnable) ||
      (state.harnessBrowser.runnable === "no" && !item.runnable);
    const text = [
      item.suite_id,
      item.suite_prefix,
      item.family,
      item.case_path,
      ...(item.metric_columns || []),
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();
    const searchMatch =
      !state.harnessBrowser.search || text.includes(state.harnessBrowser.search);
    return familyMatch && runnableMatch && searchMatch;
  });
}

function renderHarnessBrowser() {
  if (!els.hnCaseList) {
    return;
  }
  const payload = state.harnessCases;
  if (!payload) {
    return;
  }
  const source = payload.source || {};
  els.hnSourceStatus.textContent =
    source.status === "ok"
      ? `Source: ${source.root || ""}`
      : `Source: ${source.status || "unavailable"}`;

  const cases = getFilteredHarnessSuites();
  els.hnCaseCount.textContent = `${cases.length} suites`;
  if (!cases.length) {
    els.hnCaseList.className = "empty-state";
    els.hnCaseList.textContent = "No harness suites match the filters.";
    els.hnCaseDetail.className = "empty-state";
    els.hnCaseDetail.textContent = "Select a suite.";
    return;
  }

  const list = document.createElement("div");
  list.className = "catalog-list";
  list.replaceChildren(
    ...cases.map((item) => {
      const article = document.createElement("article");
      article.className = "catalog-item";
      if (state.selectedHarnessSuiteId === item.suite_id) {
        article.classList.add("is-selected");
      }
      article.innerHTML = `
        <div>
          <p class="catalog-title">${escapeHtml(item.suite_id)}</p>
          <p class="catalog-meta">${escapeHtml(item.family || "")} · ${escapeHtml(item.suite_prefix || "")}</p>
        </div>
        <span class="model-chip">${item.runnable ? "runnable" : "schema-only"}</span>
      `;
      article.addEventListener("click", () => {
        state.selectedHarnessSuiteId = item.suite_id;
        renderHarnessBrowser();
      });
      return article;
    }),
  );
  els.hnCaseList.className = "";
  els.hnCaseList.replaceChildren(list);

  const selected =
    cases.find((item) => item.suite_id === state.selectedHarnessSuiteId) || cases[0];
  state.selectedHarnessSuiteId = selected.suite_id;
  renderCaseDetail(els.hnCaseDetail, [
    ["suite_id", selected.suite_id],
    ["suite_prefix", selected.suite_prefix],
    ["family", selected.family],
    ["model_in_bench_id", selected.model_in_bench_id],
    ["runnable", selected.runnable],
    ["case_path", selected.case_path],
    ["metric_columns", (selected.metric_columns || []).join(", ")],
  ]);
}

function renderCaseDetail(target, rows) {
  const dl = document.createElement("dl");
  dl.className = "key-values case-detail";
  dl.replaceChildren(
    ...rows.flatMap(([key, value]) => {
      const dt = element("dt", key);
      let dd;
      if (value && typeof value === "object" && value.href) {
        dd = document.createElement("dd");
        const link = document.createElement("a");
        link.className = "source-link";
        link.href = value.href;
        link.target = "_blank";
        link.rel = "noopener";
        link.textContent = value.label || value.href;
        dd.append(link);
      } else {
        dd = element("dd", value == null ? "" : String(value));
      }
      return [dt, dd];
    }),
  );
  target.className = "";
  target.replaceChildren(dl);
}

function renderError(error) {
  els.metrics.replaceChildren();
  els.topologyMap.textContent = "";
  els.routerDetails.replaceChildren(
    element("dt", "Error"),
    element("dd", error.message || String(error)),
  );
  els.serverTable.replaceChildren();
  if (els.pgCaseList) {
    els.pgCaseList.className = "empty-state";
    els.pgCaseList.textContent = "Snapshot unavailable.";
  }
  if (els.hnCaseList) {
    els.hnCaseList.className = "empty-state";
    els.hnCaseList.textContent = "Snapshot unavailable.";
  }
}

function getModelIds(snapshot) {
  const fromRouter = (snapshot.routers || []).flatMap((router) =>
    (router.models || []).map((model) => model.id || model),
  );
  const fromServers = (snapshot.servers || []).flatMap((server) => server.models || []);
  return Array.from(new Set([...fromRouter, ...fromServers].filter(Boolean))).sort();
}

function uniqueSorted(values) {
  return Array.from(new Set(values.filter(Boolean))).sort();
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
