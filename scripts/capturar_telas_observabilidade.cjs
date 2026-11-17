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
    const grafana = await browser.newContext({ viewport: { width: 1600, height: 1000 } });
    // A UI do Grafana redireciona para /login (Basic Auth so vale para a API): o POST /login grava o cookie de
    // sessao no contexto do navegador.
    const login = await grafana.request.post(`${GRAFANA}/login`, {
      data: { user: process.env.GRAFANA_USUARIO, password: process.env.GRAFANA_SENHA },
    });
    if (!login.ok()) {
      throw new Error(`login no Grafana falhou: HTTP ${login.status()}`);
    }
    const pagina = await grafana.newPage();
    // Diagnostico do que a UI viu: erros do console e respostas das consultas dos paineis.
    const diagnostico = [];
    pagina.on("console", (msg) => {
      if (msg.type() === "error") diagnostico.push(`[console] ${msg.text()}`);
    });
    pagina.on("pageerror", (erro) => diagnostico.push(`[pageerror] ${erro.message}`));
    pagina.on("response", async (resposta) => {
      if (resposta.url().includes("/api/ds/query") || resposta.status() >= 400) {
        let corpo = "";
        try {
          corpo = (await resposta.text()).slice(0, 500);
        } catch {
          corpo = "(sem corpo)";
        }
        diagnostico.push(`[http ${resposta.status()}] ${resposta.request().method()} ${resposta.url()} ${corpo}`);
      }
    });
    for (const uid of DASHBOARDS) {
      diagnostico.push(`=== dashboard ${uid}`);
      await pagina.goto(`${GRAFANA}/d/${uid}?orgId=1&from=now-30m&to=now&kiosk`, { waitUntil: "networkidle" });
      await pagina.waitForTimeout(8000);
      await pagina.screenshot({ path: path.join(OUT_DIR, `grafana-${uid}.png`), fullPage: true });
      console.log(`[telas] grafana-${uid}.png`);
    }
    fs.writeFileSync(path.join(OUT_DIR, "grafana-diagnostico.log"), diagnostico.join("\n") + "\n");

    const trace = JSON.parse(fs.readFileSync(path.join(process.env.OUT_DIR, "trace_jaeger.json"), "utf8"));
    const traceId = trace.traceID;
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
