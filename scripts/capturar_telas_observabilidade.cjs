// Captura telas dos dashboards do Grafana e do trace validado no Jaeger (evidencia da Fase 4).
// Chamado por scripts/validar_observabilidade.sh com CAPTURAR_TELAS=true, enquanto os port-forwards estao abertos.
// Requer o pacote "playwright" (com Chromium) acessivel via NODE_PATH.
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const GRAFANA = process.env.GRAFANA_URL;
const JAEGER = process.env.JAEGER_URL;
const OUT_DIR = path.join(process.env.OUT_DIR, "telas");
const DASHBOARDS = ["oficina-overview", "oficina-saga", "oficina-execution", "oficina-billing"];

(async () => {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const browser = await chromium.launch();
  try {
    const grafana = await browser.newContext({
      viewport: { width: 1600, height: 1000 },
      httpCredentials: { username: process.env.GRAFANA_USUARIO, password: process.env.GRAFANA_SENHA },
    });
    const pagina = await grafana.newPage();
    for (const uid of DASHBOARDS) {
      await pagina.goto(`${GRAFANA}/d/${uid}?orgId=1&from=now-30m&to=now&kiosk`, { waitUntil: "networkidle" });
      await pagina.waitForTimeout(5000);
      await pagina.screenshot({ path: path.join(OUT_DIR, `grafana-${uid}.png`), fullPage: true });
      console.log(`[telas] grafana-${uid}.png`);
    }

    const trace = JSON.parse(fs.readFileSync(path.join(process.env.OUT_DIR, "trace_jaeger.json"), "utf8"));
    const traceId = trace.data[0].traceID;
    const jaeger = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
    await jaeger.goto(`${JAEGER}/trace/${traceId}`, { waitUntil: "networkidle" });
    await jaeger.waitForTimeout(3000);
    await jaeger.screenshot({ path: path.join(OUT_DIR, `jaeger-trace-${traceId}.png`), fullPage: true });
    console.log(`[telas] jaeger-trace-${traceId}.png`);
  } finally {
    await browser.close();
  }
})().catch((erro) => {
  console.error(`[telas] falha: ${erro.message}`);
  process.exit(1);
});
