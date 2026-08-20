(function () {
  const SUITE_ID = "longbench_v2";

  function derivePreset(row) {
    const length = String(row.lb_length || "unknown").replace(/,/g, "-");
    const difficulty = row.lb_difficulty || "all";
    const scale = String(row.workload_scale || "");
    const thinking = String(row.bench_args || "");
    const cot =
      scale.split(";").includes("cot") ||
      thinking.includes('"enable_thinking":"true"') ||
      thinking.includes('"enable_thinking": "true"')
        ? "cot"
        : "nocot";
    return `${length}_${difficulty}_${cot}`;
  }

  function enrichRows(rows) {
    return rows.map((row) => ({
      ...row,
      preset: derivePreset(row),
    }));
  }

  function mountToolbar(slotEl, hostApi) {
    slotEl.replaceChildren();

    const presetLabel = document.createElement("label");
    presetLabel.innerHTML = 'Harness preset <select id="lb-viz-preset"><option value="all">All</option></select>';
    slotEl.append(presetLabel);

    const emLabel = document.createElement("label");
    emLabel.innerHTML =
      'EM min <input id="lb-viz-em-min" type="number" min="0" max="1" step="0.01" value="0">';
    slotEl.append(emLabel);

    const presetSelect = presetLabel.querySelector("#lb-viz-preset");
    const emInput = emLabel.querySelector("#lb-viz-em-min");

    const filters = hostApi.getFilters();
    const pluginFilters = hostApi.getPluginFilters();
    emInput.value = String(pluginFilters.emMin ?? 0);
    presetSelect.value = pluginFilters.preset ?? "all";

    const presets = uniqueSorted(
      enrichRows(hostApi.state.harness?.rows || [])
        .map((row) => row.preset)
        .filter(Boolean),
    );
    presetSelect.replaceChildren(
      ...["all", ...presets].map((value) => {
        const option = document.createElement("option");
        option.value = value;
        option.textContent = value === "all" ? "All" : value;
        return option;
      }),
    );
    presetSelect.value = pluginFilters.preset ?? "all";

    presetSelect.addEventListener("change", () => {
      hostApi.setPluginFilter("preset", presetSelect.value);
      hostApi.rerender();
    });

    const syncEm = () => {
      let emMin = Number(emInput.value);
      if (!Number.isFinite(emMin)) {
        emMin = 0;
      }
      hostApi.setPluginFilter("emMin", emMin);
      hostApi.rerender();
    };
    emInput.addEventListener("change", syncEm);
    emInput.addEventListener("input", syncEm);
  }

  /** Harness LIMIT from bench_args / workload_scale (not column lb_limit — full pool stores lb_limit=n). */
  function harnessLimit(row) {
    const args = String(row.bench_args || "");
    let m = args.match(/"limit"\s*:\s*(\d+)/);
    if (m) {
      return Number(m[1]);
    }
    m = args.match(/(?:^|[,\s;])limit\s*[:=]\s*(\d+)/i);
    if (m) {
      return Number(m[1]);
    }
    const scale = String(row.workload_scale || "");
    m = scale.match(/(?:^|[;])limit=([^;]+)/);
    if (m) {
      const tag = String(m[1]).trim().toLowerCase();
      if (tag === "all" || tag === "0") {
        return 0;
      }
      const n = Number(tag);
      if (Number.isFinite(n)) {
        return n;
      }
    }
    return 0;
  }

  function filterRow(row, filters, pluginFilters) {
    // Hide harness LIMIT>0 smoke/qualify rows; viz is full-pool (limit=0) only.
    if (harnessLimit(row) > 0) {
      return false;
    }
    const status = String(row.status || "").toUpperCase();
    const em = Number(row.lb_em);
    const emMin = Number.isFinite(pluginFilters.emMin) ? pluginFilters.emMin : 0;
    if (status !== "PASS" || !Number.isFinite(em) || !(em > emMin)) {
      return false;
    }
    const preset = row.preset || "";
    if (pluginFilters.preset && pluginFilters.preset !== "all" && preset !== pluginFilters.preset) {
      return false;
    }
    return true;
  }

  function tableColumns(metric) {
    const base = [
      "date",
      "case_id",
      "deploy_mode",
      "model",
      "hw",
      "be",
      "worktree",
      "preset",
      "lb_em",
      "total_tok_per_s",
    ];
    if (metric && !base.includes(metric)) {
      base.push(metric);
    }
    return base;
  }

  function numericColumns(metric) {
    const cols = new Set(["lb_em", "total_tok_per_s"]);
    if (metric) {
      cols.add(metric);
    }
    return cols;
  }

  function statusLine(ctx) {
    const emMin = Number.isFinite(ctx.pluginFilters?.emMin) ? ctx.pluginFilters.emMin : 0;
    return ` · PASS · lb_em > ${emMin} · full-pool only (limit=0)`;
  }

  function defaultPluginFilters() {
    return { preset: "all", emMin: 0 };
  }

  function uniqueSorted(values) {
    return Array.from(new Set(values)).sort();
  }

  window.HarnessVizPlugins = window.HarnessVizPlugins || {};
  window.HarnessVizPlugins[SUITE_ID] = {
    suiteId: SUITE_ID,
    defaultMetric: "total_tok_per_s",
    enrichRows,
    mountToolbar,
    filterRow,
    tableColumns,
    numericColumns,
    statusLine,
    defaultPluginFilters,
  };
})();
