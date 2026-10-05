// Relatório de captação (antiga planilha "RELATÓRIO DE CAPTAÇÃO"): regras e a visão total, usados em
// captacao.html (aba Relatório) e em gerencia.html (área Captação). Não contém dados: eles vêm do banco depois do login.
(function(){
  const CIDADES=['Itajaí','Navegantes'];
  const CAMPOS=[['prospeccao','Prospecção'],['atendimentos','Atendimentos'],['em_andamento','Em andamento'],['pos_captados','Pós captados'],['novas_captacoes','Novas captações']];
  const COLUNAS='id,quadro_id,inicio,cidade,prospeccao,atendimentos,em_andamento,pos_captados,novas_captacoes,referencias,atualizado_em,atualizado_por';
  const MESES=['jan','fev','mar','abr','mai','jun','jul','ago','set','out','nov','dez'];
  const pad=n=>String(n).padStart(2,'0');
  const safe=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const totCap=r=>(r.pos_captados||0)+(r.novas_captacoes||0);
  const soma=(list,f)=>list.reduce((s,r)=>s+(f==='total'?totCap(r):(r[f]||0)),0);

  // Semanas de segunda a sexta, cortadas no mês (01 a 04/09, 07 a 11/09…), como na planilha.
  function semanasDoMes(ym){
    const [a,m]=ym.split('-').map(Number),out=[];let cur=null;
    for(let d=1;d<=new Date(a,m,0).getDate();d++){const wd=new Date(a,m-1,d).getDay();
      if(wd===0||wd===6){cur=null;continue}
      if(!cur){cur={inicio:`${a}-${pad(m)}-${pad(d)}`,ini:d,fim:d};out.push(cur)}else cur.fim=d}
    return out.map(s=>({...s,nome:s.ini===s.fim?`${pad(s.ini)}/${pad(m)}`:`${pad(s.ini)} a ${pad(s.fim)}/${pad(m)}`}));
  }
  // Referências digitadas livremente ("AP1643/AP1645", "AP1625 - CA0475", "AP1641AP1642"): separa em REFs.
  function refsDe(txt){
    const lista=[],estranhas=[];
    for(let t of String(txt||'').toUpperCase().split(/[\/,;\n]|\s-\s|\sE\s/)){t=t.trim();if(!t)continue;
      const m=t.replace(/\s+/g,'').match(/[A-Z]{2,4}\d{3,5}/g);
      if(m&&m.join('')===t.replace(/\s+/g,''))lista.push(...m);else estranhas.push(t)}
    return {lista,estranhas};
  }
  // Em vermelho: referências que não batem com o total captado, REF repetida no mês (mesma captadora) e REF fora do padrão.
  function problemas(r,doMes){
    const out=[...(r.avisos||[])],{lista,estranhas}=refsDe(r.referencias),n=lista.length+estranhas.length,t=totCap(r);
    if((t||n)&&n!==t)out.push(`${n} referência${n===1?'':'s'} para ${t} captado${t===1?'':'s'}`);
    estranhas.forEach(x=>out.push(x.startsWith('(SEM REF:')?`cartão sem REF no título: ${x.slice(9,-1).trim()}`:`REF fora do padrão: ${x}`));
    const mesmas=doMes.filter(x=>x.quadro_id===r.quadro_id).flatMap(x=>x===r?[]:refsDe(x.referencias).lista);
    const rep=[...new Set(lista.filter((x,i)=>lista.indexOf(x)!==i||mesmas.includes(x)))];
    if(rep.length)out.push(`REF repetida no mês: ${rep.join(', ')}`);
    return out;
  }

  // Visão total (gerência): números do mês, por captadora, por semana, acumulado do ano e o detalhe com os erros.
  // rel = linhas do ano todo; caps = captadoras [{id,nome}]; cidade = '' para as duas.
  function htmlTotal({rel,caps:todas,ym,cidade,periodos=[]}){
    const nomeQ=id=>todas.find(q=>q.id===id)?.nome||'?',filtroC=r=>!cidade||r.cidade===cidade;
    const doMes=rel.filter(r=>r.inicio.startsWith(ym)),mes=doMes.filter(filtroC),sems=semanasDoMes(ym),ano=rel.filter(filtroC);
    // Corretoras que saíram (quadro inativo) só aparecem onde têm números: no mês, ou no ano para o acumulado.
    const caps=todas.filter(q=>q.ativo!==false||mes.some(r=>r.quadro_id===q.id));
    const capsAno=todas.filter(q=>q.ativo!==false||ano.some(r=>r.quadro_id===q.id));
    const cel=v=>`<td class="n${v?'':' z'}">${v}</td>`;
    const kpis=`<div class="kpis">${CAMPOS.map(([f,n])=>`<div class="kpi"><small>${n}</small><strong>${soma(mes,f)}</strong></div>`).join('')}<div class="kpi" style="border-color:#bcd9cc"><small>Total captado</small><strong>${soma(mes,'total')}</strong></div></div>`;
    const porCap=`<div><h2 class="cr-h">Resumo do mês por captadora</h2><div class="tbl-wrap"><table><thead><tr><th>Captadora</th>${CAMPOS.map(([,n])=>`<th>${n}</th>`).join('')}<th>Total captado</th></tr></thead><tbody>
      ${caps.map(q=>{const l=mes.filter(r=>r.quadro_id===q.id);return `<tr><td><button class="link" data-rq="${q.id}" style="padding-left:0">${safe(q.nome)}</button></td>${CAMPOS.map(([f])=>cel(soma(l,f))).join('')}<td class="n"><strong>${soma(l,'total')}</strong></td></tr>`}).join('')}</tbody>
      <tfoot><tr><td>Total</td>${CAMPOS.map(([f])=>cel(soma(mes,f))).join('')}${cel(soma(mes,'total'))}</tr></tfoot></table></div></div>`;
    const porSem=`<div><h2 class="cr-h">Total captado por semana <small>(pós + novas)</small></h2><div class="tbl-wrap"><table><thead><tr><th>Semana</th>${caps.map(q=>`<th>${safe(q.nome)}</th>`).join('')}<th>Total</th><th>Prospecção</th></tr></thead><tbody>
      ${sems.map(s=>{const l=mes.filter(r=>r.inicio===s.inicio);return `<tr><td>${s.nome}</td>${caps.map(q=>cel(soma(l.filter(r=>r.quadro_id===q.id),'total'))).join('')}<td class="n"><strong>${soma(l,'total')}</strong></td>${cel(soma(l,'prospeccao'))}</tr>`}).join('')}</tbody></table></div></div>`;
    const mesesCom=[...new Set(ano.map(r=>+r.inicio.slice(5,7)))].sort((x,y)=>x-y);
    const acum=`<div><h2 class="cr-h">Acumulado de ${ym.slice(0,4)} <small>(total captado por mês)</small></h2><div class="tbl-wrap"><table><thead><tr><th>Captadora</th>${mesesCom.map(k=>`<th>${MESES[k-1]}</th>`).join('')}<th>Novas</th><th>Pós</th><th>Total</th></tr></thead><tbody>
      ${capsAno.map(q=>{const l=ano.filter(r=>r.quadro_id===q.id);return `<tr><td>${safe(q.nome)}${q.ativo===false?' <small class="muted">(saiu)</small>':''}</td>${mesesCom.map(k=>cel(soma(l.filter(r=>+r.inicio.slice(5,7)===k),'total'))).join('')}${cel(soma(l,'novas_captacoes'))}${cel(soma(l,'pos_captados'))}<td class="n"><strong>${soma(l,'total')}</strong></td></tr>`}).join('')}</tbody>
      <tfoot><tr><td>Total</td>${mesesCom.map(k=>cel(soma(ano.filter(r=>+r.inicio.slice(5,7)===k),'total'))).join('')}${cel(soma(ano,'novas_captacoes'))}${cel(soma(ano,'pos_captados'))}${cel(soma(ano,'total'))}</tr></tfoot></table></div></div>`;
    const erros=mes.filter(r=>problemas(r,doMes).length).length;
    const detalhe=`<div><h2 class="cr-h">Detalhe das semanas ${erros?`<small style="color:var(--red)">· ${erros} linha${erros===1?'':'s'} com erro em vermelho</small>`:''}</h2><div class="tbl-wrap"><table><thead><tr><th>Semana</th><th>Captadora</th><th>Cidade</th>${CAMPOS.map(([,n])=>`<th>${n}</th>`).join('')}<th>Total</th><th>Referências</th></tr></thead><tbody>
      ${sems.flatMap(s=>mes.filter(r=>r.inicio===s.inicio).sort((x,y)=>nomeQ(x.quadro_id).localeCompare(nomeQ(y.quadro_id))||x.cidade.localeCompare(y.cidade)).map(r=>{const p=problemas(r,doMes);
        const aj=f=>r._ajustado?.includes(f)?` class="n aj" title="Ajustado à mão (o quadro dizia ${safe(r._auto?.[f]??0)})"`:' class="n"';
        return `<tr class="${p.length?'erro':''}"><td>${s.nome}</td><td>${safe(nomeQ(r.quadro_id))}</td><td>${r.cidade}</td>${CAMPOS.map(([f])=>`<td${aj(f)}>${r[f]||0}</td>`).join('')}<td class="n"><strong>${totCap(r)}</strong></td><td style="white-space:normal;min-width:220px">${safe(r.referencias||'')}${r._ajustado?.length?' <small class="muted">(ajustado)</small>':''}${p.length?`<div class="prob">${safe(p.join(' · '))}</div>`:''}</td></tr>`})).join('')||`<tr><td colspan="${CAMPOS.length+5}" class="muted">Nada lançado neste mês.</td></tr>`}</tbody></table></div></div>`;
    // Resumos prontos da planilha (ex.: 1º semestre, que inclui meses que não existem semana a semana), do ano escolhido.
    const anoTxt=ym.slice(0,4),pers=[...new Set(periodos.filter(p=>p.periodo.includes(anoTxt)).map(p=>p.periodo))];
    const resumos=pers.map(per=>{const l=periodos.filter(p=>p.periodo===per).sort((a,b)=>a.posicao-b.posicao),t=x=>(x.novos||0)+(x.pos||0);
      const c=v=>v==null?'<td class="n z">–</td>':cel(v);
      return `<div><h2 class="cr-h">Resumo do ${safe(per)} <small>(como está na planilha; inclui meses que não existem semana a semana)</small></h2><div class="tbl-wrap"><table><thead><tr><th>Captadora</th><th>Novos imóveis</th><th>Imóveis da pós</th><th>Total</th></tr></thead><tbody>
        ${l.map(x=>`<tr><td>${safe(x.captadora)}</td>${c(x.novos)}${c(x.pos)}<td class="n"><strong>${t(x)}</strong></td></tr>`).join('')}</tbody>
        <tfoot><tr><td>Total</td>${cel(l.reduce((s,x)=>s+(x.novos||0),0))}${cel(l.reduce((s,x)=>s+(x.pos||0),0))}${cel(l.reduce((s,x)=>s+t(x),0))}</tr></tfoot></table></div></div>`}).join('');
    return kpis+porCap+porSem+acum+resumos+detalhe;
  }
  // Resumos de período (só a gerência e o acesso geral leem; para as captadoras volta vazio).
  async function carregarPeriodos(db){const {data,error}=await db.from('captacao_resumo_periodo').select('periodo,captadora,novos,pos,posicao');return error?[]:data}

  // Busca as linhas de um ano inteiro (paginado).
  async function carregarAno(db,ano){
    const all=[];
    for(let from=0;;from+=1000){const {data,error}=await db.from('captacao_relatorio').select(COLUNAS).gte('inicio',`${ano}-01-01`).lte('inicio',`${ano}-12-31`).order('inicio').range(from,from+999);
      if(error)throw error;all.push(...data);if(data.length<1000)break}
    return all;
  }

  // ---------- Números que vêm do quadro (de outubro/2026 em diante; setembro ficou digitado) ----------
  // Decisão da gerência em 29/09/2026. Regras:
  // - captado = cartão que chegou na coluna de captado (CAPTADO). A captação fica gravada em captacao_captados (gatilho no banco)
  //   e NÃO some quando o cartão é arquivado, excluído ou levado para uma coluna depois dela; só sai se voltar para antes (engano);
  // - nova ou pós = etiqueta do cartão (sem etiqueta conta como nova, com aviso); cidade = etiqueta ITAJAÍ/NAVEGANTES (sem etiqueta = Itajaí, com aviso);
  // - em andamento = cartões entre a primeira coluna e a de captado no fim da semana (arquivados não contam depois de arquivados);
  // - referências = a REF do começo do título de cada cartão captado.
  // O que a captadora digita nesses campos vale no lugar do quadro ("ajustado"); apagando, volta o número do quadro.
  const AUTO_DESDE='2026-10';
  const AUTO=['em_andamento','pos_captados','novas_captacoes','referencias'];
  const ehAuto=ym=>ym>=AUTO_DESDE;
  async function pega(db,t,c){const all=[];for(let from=0;;from+=1000){const {data,error}=await db.from(t).select(c).range(from,from+999);if(error)throw error;all.push(...data);if(data.length<1000)break}return all}
  async function carregarQuadros(db){
    const [cols,etqs,cards,captados]=await Promise.all([pega(db,'captacao_colunas','id,quadro_id,nome,posicao,captado'),pega(db,'captacao_etiquetas','id,quadro_id,nome'),
      pega(db,'captacao_cartoes','id,quadro_id,coluna_id,titulo,referencia,etiquetas,modelo,criado_em,movido_em,arquivado_em'),
      pega(db,'captacao_captados','id,quadro_id,cartao_id,referencia,titulo,cidade,pos,sem_cidade,sem_tipo,captado_em')]);
    const reais=cards.filter(c=>!c.modelo);
    // Histórico de criação, mudança de coluna e arquivamento (para saber onde o cartão estava no fim de cada semana).
    const hist=reais.length?(await pega(db,'captacao_historico','cartao_id,tipo,para_coluna,criado_em')).filter(h=>['criado','movido','arquivado','restaurado'].includes(h.tipo)):[];
    return {cols,etqs,cards:reais,hist,captados};
  }
  const diaLocal=ts=>{const d=new Date(ts);return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`};
  // Linhas do mês calculadas pelo quadro: uma por captadora, semana e cidade (só as que têm algum número).
  function autoDoMes(dados,ym){
    if(!dados||!ehAuto(ym))return [];
    const sems=semanasDoMes(ym),[a,m]=ym.split('-').map(Number),fimMes=`${a}-${pad(m)}-${pad(new Date(a,m,0).getDate())}`;
    // Cada semana vai do seu início até a véspera da próxima (sábado e domingo entram na semana que acabou).
    const faixas=sems.map((s,i)=>({...s,ate:i<sems.length-1?diaAntes(sems[i+1].inicio):fimMes}));
    const hoje=diaLocal(Date.now()),out=[];
    const porCartao={};dados.hist.forEach(h=>(porCartao[h.cartao_id]??=[]).push(h));Object.values(porCartao).forEach(l=>l.sort((x,y)=>x.criado_em.localeCompare(y.criado_em)));
    const quadrosIds=[...new Set([...dados.cols.map(c=>c.quadro_id),...(dados.captados||[]).map(c=>c.quadro_id)])];
    for(const q of quadrosIds){
      const cols=dados.cols.filter(c=>c.quadro_id===q).sort((x,y)=>x.posicao-y.posicao);
      // Coluna de captado: a marcada no banco (CAPTADO); sem marca, a última. Em andamento = entre a primeira e ela.
      const capCol=cols.find(c=>c.captado)||cols[cols.length-1],primeira=cols[0];
      const meio=new Set(cols.filter(c=>primeira&&capCol&&c.posicao>primeira.posicao&&c.posicao<capCol.posicao).map(c=>c.nome.toLowerCase()));
      const nomeCol=Object.fromEntries(cols.map(c=>[c.id,c.nome.toLowerCase()]));
      const etq=Object.fromEntries(dados.etqs.filter(e=>e.quadro_id===q).map(e=>[e.id,e.nome.toUpperCase()]));
      const cards=dados.cards.filter(c=>c.quadro_id===q),caps=(dados.captados||[]).filter(c=>c.quadro_id===q);
      const cidadeDe=c=>c.etiquetas.map(id=>etq[id]||'').some(x=>x.includes('NAVEGANTES'))?'Navegantes':'Itajaí';
      // Coluna do cartão num momento (fim do dia "ate"): último registro até ali; sem registro, a coluna atual se já existia.
      // Arquivado (antes desse momento) = fora do quadro.
      const colEm=(c,ate)=>{const lim=new Date(ate+'T23:59:59').toISOString();
        if(ate>=hoje)return c.arquivado_em?null:nomeCol[c.coluna_id];
        const h=(porCartao[c.id]||[]).filter(x=>x.criado_em<=lim).pop();
        if(h)return h.tipo==='arquivado'?null:(h.para_coluna||nomeCol[c.coluna_id]||'').toLowerCase();
        if(c.arquivado_em&&c.arquivado_em<=lim)return null;
        return !(porCartao[c.id]||[]).length&&c.criado_em<=lim?nomeCol[c.coluna_id]:null};
      for(const f of faixas){
        if(f.inicio>hoje)continue;
        for(const cidade of CIDADES){
          const linha={quadro_id:q,inicio:f.inicio,cidade,em_andamento:0,pos_captados:0,novas_captacoes:0,referencias:null,avisos:[]},refs=[];
          // Captações gravadas (continuam contando mesmo que o cartão já tenha saído do quadro).
          for(const k of caps){if(k.cidade!==cidade)continue;const d=diaLocal(k.captado_em);if(d<f.inicio||d>f.ate)continue;
            k.pos?linha.pos_captados++:linha.novas_captacoes++;refs.push(k.referencia||`(sem REF: ${k.titulo.slice(0,30)})`);
            if(k.sem_cidade)linha.avisos.push(`${k.referencia||k.titulo.slice(0,20)} sem etiqueta de cidade (contado em Itajaí)`);
            if(k.sem_tipo)linha.avisos.push(`${k.referencia||k.titulo.slice(0,20)} sem etiqueta NOVA ou PÓS (contado como nova)`)}
          for(const c of cards){if(cidadeDe(c)!==cidade)continue;const col=colEm(c,f.ate);if(col&&meio.has(col))linha.em_andamento++}
          linha.referencias=refs.join(' / ')||null;
          if(linha.em_andamento||linha.pos_captados||linha.novas_captacoes)out.push(linha);
        }
      }
    }
    return out;
  }
  function diaAntes(s){const d=new Date(s+'T12:00');d.setDate(d.getDate()-1);return diaLocal(d)}
  // Junta o digitado (rel) com o que veio do quadro: nos meses automáticos, campo digitado vale no lugar do quadro.
  // Cada linha devolvida tem _auto (a linha do quadro), _db (a digitada), _ajustado (campos digitados que trocaram o do quadro) e avisos.
  function efetivas(rel,dados,ano){
    const out=rel.filter(r=>!ehAuto(r.inicio.slice(0,7))).map(r=>({...r,_db:r,_ajustado:[],avisos:[]}));
    const meses=[...Array(12)].map((_,i)=>`${ano}-${pad(i+1)}`).filter(ehAuto);
    for(const ym of meses){
      const autos=autoDoMes(dados,ym),dig=rel.filter(r=>r.inicio.startsWith(ym)),chaves=new Set([...autos,...dig].map(r=>`${r.quadro_id}|${r.inicio}|${r.cidade}`));
      for(const k of chaves){const [q,inicio,cidade]=k.split('|'),a=autos.find(r=>r.quadro_id===q&&r.inicio===inicio&&r.cidade===cidade),d=dig.find(r=>r.quadro_id===q&&r.inicio===inicio&&r.cidade===cidade);
        const e={quadro_id:q,inicio,cidade,prospeccao:d?.prospeccao??null,atendimentos:d?.atendimentos??null,_auto:a||null,_db:d||null,_ajustado:[],avisos:a?.avisos||[]};
        for(const f of AUTO){if(d&&d[f]!=null){e[f]=d[f];if(a)e._ajustado.push(f)}else e[f]=a?a[f]:null}
        out.push(e)}
    }
    return out.sort((x,y)=>x.inicio.localeCompare(y.inicio));
  }

  // Estilos da visão total (as duas páginas usam os mesmos nomes de classe).
  const CSS=`.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}
    .kpi{background:#fff;border:1px solid var(--line);border-radius:14px;padding:12px 14px}.kpi small{display:block;color:var(--muted);font-size:.74rem;font-weight:750;text-transform:uppercase;letter-spacing:.03em}.kpi strong{font-size:1.6rem;font-variant-numeric:tabular-nums}
    .cr .tbl-wrap{overflow-x:auto;background:#fff;border:1px solid var(--line);border-radius:14px}
    .cr table{border-collapse:collapse;width:100%;font-size:.86rem}
    .cr th,.cr td{padding:8px 10px;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}
    .cr th{font-size:.72rem;text-transform:uppercase;letter-spacing:.03em;color:var(--muted);background:#f6f8f9;white-space:normal;min-width:70px;vertical-align:bottom}
    .cr td.n{text-align:right;font-variant-numeric:tabular-nums}.cr td.z{color:#b7c0c7}
    .cr tr:last-child td{border-bottom:0}.cr tfoot td{font-weight:800;background:#f6f8f9}
    .cr tr.erro td{background:#fdf0f0}.cr .prob{color:var(--red);font-size:.78rem;font-weight:650;white-space:normal}
    .cr td.aj{background:#fff6dc}
    .cr .cr-h{margin:0 0 8px}.cr h2 small{font-family:Inter,"Segoe UI",Arial,sans-serif;font-size:.8rem;color:var(--muted);font-weight:600}`;
  const st=document.createElement('style');st.textContent=CSS;document.head.append(st);

  window.CapRel={CIDADES,CAMPOS,COLUNAS,AUTO,AUTO_DESDE,ehAuto,semanasDoMes,refsDe,problemas,totCap,soma,htmlTotal,carregarAno,carregarPeriodos,carregarQuadros,autoDoMes,efetivas};
})();
