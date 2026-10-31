// Pesquisa depois da visita (30/10/2026). O relógio do banco (pg_cron, a cada 5 minutos, ver supabase/visitas.sql) chama esta função.
// Ela pega as visitas cujo último imóvel confirmado foi há 30 minutos ou mais (visitas_para_avaliar), manda o e-mail
// "como foi a visita?" com o link visita.html?c=<token>&avaliar=1 e marca o envio (visita_marcar_envio).
// E-mail por SMTP, nos segredos SMTP_HOST, SMTP_PORT (465 = SSL), SMTP_USER, SMTP_PASS e SMTP_FROM
// (ex.: "Araujo Locação <visitas@araujolocacao.com.br>"). Sem eles a função não manda nada nem marca: as visitas esperam
// (até 2 dias) e a aba Visitas mostra "E-mail na fila".
// Pode ser chamada a mais sem problema: só manda o que já está na hora e ainda não foi enviado.
import { createClient } from "npm:@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const PORTAL = Deno.env.get("PORTAL_URL") ?? "https://portal-interno-rust.vercel.app";
const json = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
const quando = (d: string) => {
  const f = (o: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo", ...o }).format(new Date(d));
  return `${f({ weekday: "long" })}, ${f({ day: "2-digit", month: "2-digit" })} às ${f({ hour: "2-digit", minute: "2-digit" }).replace(":", "h")}`;
};

type Imovel = { referencia: string | null; endereco: string; data_hora: string };
type Visita = { id: string; token: string; nome: string; email: string; corretora: string | null; imoveis: Imovel[] };

function montar(v: Visita) {
  const nome = (v.nome || "").trim().split(/\s+/)[0] || "";
  const link = `${PORTAL}/visita.html?c=${encodeURIComponent(v.token)}&avaliar=1`;
  const varios = v.imoveis.length > 1;
  const quem = v.corretora ? ` com a ${v.corretora}` : "";
  const assunto = `${nome ? nome + ", como" : "Como"} foi a sua visita?`;
  const texto = `Olá${nome ? ", " + nome : ""}!\n\nObrigado por visitar ${varios ? "os imóveis" : "o imóvel"}${quem}, da Araujo Locação.\n` +
    v.imoveis.map((i) => `- ${quando(i.data_hora)}: ${i.endereco}${i.referencia ? ` (${i.referencia})` : ""}`).join("\n") +
    `\n\nConte pra gente como foi, em menos de 1 minuto:\n${link}\n\nAraujo Locação`;
  const html = `<!doctype html><html lang="pt-BR"><body style="margin:0;background:#f4f6f9;font-family:Arial,Helvetica,sans-serif;color:#1d2730">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6f9;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:16px;overflow:hidden;border:1px solid #dde3ea">
<tr><td align="center" style="padding:20px;border-bottom:4px solid #7FA3D0"><img src="${PORTAL}/logo-araujo.jpg" alt="Araujo Locação" height="56" style="height:56px;width:auto"></td></tr>
<tr><td style="padding:26px 26px 8px"><h1 style="margin:0 0 10px;font-size:22px;color:#004AAD">Como foi a sua visita${nome ? ", " + esc(nome) : ""}?</h1>
<p style="margin:0 0 16px;font-size:15px;line-height:1.5">Obrigado por visitar ${varios ? "os imóveis" : "o imóvel"}${esc(quem)}, da Araujo Locação. A sua opinião leva menos de 1 minuto e ajuda a gente a atender cada vez melhor.</p>
${v.imoveis.map((i) => `<p style="margin:0 0 10px;padding:12px 14px;background:#eef3fa;border-radius:10px;font-size:14px;line-height:1.4"><b>${esc(quando(i.data_hora))}</b><br>${esc(i.endereco)}${i.referencia ? `<br><span style="color:#66727c">Imóvel ${esc(i.referencia)}</span>` : ""}</p>`).join("")}
</td></tr>
<tr><td align="center" style="padding:14px 26px 28px"><a href="${esc(link)}" style="display:inline-block;background:#004AAD;color:#ffffff;text-decoration:none;font-weight:bold;font-size:16px;padding:14px 28px;border-radius:12px">Avaliar a visita</a></td></tr>
</table><p style="font-size:12px;color:#66727c;margin:14px 0 0">Araujo Locação · Itajaí e Navegantes (SC)</p></td></tr></table></body></html>`;
  return { assunto, texto, html };
}

Deno.serve(async () => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await sb.rpc("visitas_para_avaliar");
  if (error) return json({ erro: error.message }, 500);
  const fila = (data ?? []) as Visita[];
  if (!fila.length) return json({ enviados: 0 });

  const host = Deno.env.get("SMTP_HOST"), user = Deno.env.get("SMTP_USER"), pass = Deno.env.get("SMTP_PASS");
  const from = Deno.env.get("SMTP_FROM") ?? user;
  if (!host || !user || !pass || !from) return json({ aguardando: fila.length, erro: "sem_smtp" });
  const port = Number(Deno.env.get("SMTP_PORT") ?? 465);

  const smtp = new SMTPClient({ connection: { hostname: host, port, tls: port === 465, auth: { username: user, password: pass } } });
  let enviados = 0;
  const erros: string[] = [];
  try {
    for (const v of fila) {
      const m = montar(v);
      try {
        await smtp.send({ from, to: v.email, subject: m.assunto, content: m.texto, html: m.html });
        await sb.rpc("visita_marcar_envio", { p_id: v.id, p_erro: null });
        enviados++;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        await sb.rpc("visita_marcar_envio", { p_id: v.id, p_erro: msg });
        erros.push(msg);
      }
    }
  } finally {
    await smtp.close().catch(() => {});
  }
  return json({ enviados, erros });
});
