// Apresentação da semana: a gerência escreve o que quer ("destaque em locações é a Fran e a Thayná...")
// e o Claude devolve os slides prontos (destaques e slides livres) para ela revisar e salvar.
// Só a gerência usa (is_gestor). A chave fica no segredo ANTHROPIC_API_KEY do Supabase, nunca no site.
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resposta = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...cors, "Content-Type": "application/json" } });

const SISTEMA = `Você monta slides da reunião semanal de resultados da Araujo Locação, uma imobiliária de locação em Itajaí e Navegantes (SC).
A gerente escreve o que quer na apresentação e você devolve os slides prontos, em português do Brasil, com tom caloroso e profissional, sem emojis.

Tipos de slide:
- "destaque": reconhece UMA pessoa. Se o pedido cita várias pessoas num mesmo destaque (ex.: "destaque em locações é a Fran e a Thayná"), crie um slide de destaque para cada uma, com o mesmo título.
  - titulo: curto, ex.: "Destaque em Locações", "Destaque em Leads Próprios", "Destaque em Avaliações no Google".
  - selo: 1 a 3 palavras, ex.: "Top Performance", "Leads Próprios", "Google"; pode ficar vazio.
  - pessoa: a chave exata da lista de pessoas enviada; vazio só se a pessoa não estiver na lista.
  - mostrar_numeros: true só quando o destaque é de locações/contratos/VGL (o slide mostra contratos e VGL da semana).
  - mensagem: 1 a 3 frases de parabéns, citando o motivo do destaque.
- "livre": slide de conteúdo (aviso, meta, comemoração, resumo). Use quando o pedido não for o destaque de uma pessoa.
  - etiqueta: texto pequeno acima do título, em maiúsculas (ex.: "RECONHECIMENTO SEMANAL").
  - titulo, subtitulo (pode ficar vazio), itens (0 a 4 frases curtas) e mensagem (pode ficar vazia).
  - imagem: a chave de uma imagem da lista "imagens_disponiveis" que combine com o assunto (pela descrição); "" se nenhuma combinar. Não repita a mesma imagem em slides seguidos.
  - Um slide livre com imagem fica melhor com no máximo 3 itens curtos.
Nos campos que não se aplicam ao tipo, use "" (ou [] / false).

Regras:
- Use só os fatos do pedido e os números enviados. Nunca invente números, nomes ou acontecimentos.
- Quando citar números (leads, visitas, contratos, VGL), use exatamente os números enviados para o período.
- Siga a ordem em que os destaques aparecem no pedido.
- Em "resumo", diga em uma frase o que foi criado.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return resposta({ erro: "Use POST." }, 405);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: gestor } = await sb.rpc("is_gestor");
  if (gestor !== true) return resposta({ erro: "Só a gerência pode usar." }, 403);

  const chave = Deno.env.get("ANTHROPIC_API_KEY");
  if (!chave) return resposta({ erro: "sem_chave" }, 503);

  let corpo: { pedido?: string; periodo?: string; pessoas?: { chave: string; nome: string; funcao?: string }[]; imagens?: { chave: string; descricao?: string }[]; numeros?: unknown; destaques_atuais?: unknown };
  try { corpo = await req.json(); } catch { return resposta({ erro: "Pedido inválido." }, 400); }
  const pedido = String(corpo.pedido ?? "").trim();
  if (!pedido) return resposta({ erro: "Escreva o que você quer na apresentação." }, 400);
  if (pedido.length > 4000) return resposta({ erro: "O pedido está muito longo (máximo 4.000 letras)." }, 400);
  const pessoas = (corpo.pessoas ?? []).slice(0, 80).map((p) => ({ chave: String(p.chave), nome: String(p.nome), funcao: String(p.funcao ?? "") }));
  const imagens = (corpo.imagens ?? []).slice(0, 300).map((i) => ({ chave: String(i.chave), descricao: String(i.descricao ?? "") }));

  const slide = {
    type: "object",
    additionalProperties: false,
    required: ["tipo", "titulo", "selo", "pessoa", "mostrar_numeros", "mensagem", "etiqueta", "subtitulo", "itens", "imagem"],
    properties: {
      tipo: { type: "string", enum: ["destaque", "livre"] },
      titulo: { type: "string" },
      selo: { type: "string" },
      pessoa: { type: "string", enum: ["", ...pessoas.map((p) => p.chave)] },
      mostrar_numeros: { type: "boolean" },
      mensagem: { type: "string" },
      etiqueta: { type: "string" },
      subtitulo: { type: "string" },
      itens: { type: "array", items: { type: "string" } },
      imagem: { type: "string", enum: ["", ...imagens.map((i) => i.chave)] },
    },
  };
  const schema = {
    type: "object",
    additionalProperties: false,
    required: ["slides", "resumo"],
    properties: { slides: { type: "array", items: slide }, resumo: { type: "string" } },
  };

  const contexto = {
    periodo: corpo.periodo ?? "",
    pessoas,
    imagens_disponiveis: imagens,
    numeros_do_periodo: corpo.numeros ?? [],
    destaques_que_ja_estao_na_apresentacao: corpo.destaques_atuais ?? [],
  };

  const client = new Anthropic({ apiKey: chave });
  try {
    const r = await client.beta.messages.create({
      model: "claude-opus-5-5",
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: "medium", format: { type: "json_schema", schema } },
      system: SISTEMA,
      messages: [{
        role: "user",
        content: `Dados da semana (JSON):\n${JSON.stringify(contexto)}\n\nPedido da gerente:\n${pedido}`,
      }],
    } as never);
    if (r.stop_reason === "refusal") return resposta({ erro: "A IA não conseguiu atender este pedido. Tente escrever de outro jeito." }, 422);
    if (r.stop_reason === "max_tokens") return resposta({ erro: "O pedido gerou slides demais. Tente pedir menos de uma vez." }, 422);
    const texto = r.content.filter((b) => b.type === "text").map((b) => (b as { text: string }).text).join("");
    return resposta(JSON.parse(texto));
  } catch (e) {
    if (e instanceof Anthropic.AuthenticationError) return resposta({ erro: "chave_invalida" }, 503);
    if (e instanceof Anthropic.RateLimitError) return resposta({ erro: "Muitos pedidos seguidos. Espere um minuto e tente de novo." }, 429);
    // 400 aqui costuma ser conta da API sem crédito: a tela mostra o aviso e o detalhe.
    if (e instanceof Anthropic.BadRequestError) return resposta({ erro: "requisicao", detalhe: e.message }, 502);
    if (e instanceof Anthropic.APIError) return resposta({ erro: `Erro da IA (${e.status}). Tente de novo.` }, 502);
    if (e instanceof SyntaxError) return resposta({ erro: "A resposta da IA veio incompleta. Tente de novo." }, 502);
    throw e;
  }
});
