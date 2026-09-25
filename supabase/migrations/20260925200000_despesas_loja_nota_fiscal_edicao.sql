-- Nota fiscal nos lançamentos + edição completa após o lançamento
-- (inclusive de rateios entre lojas) por quem tem acesso às lojas envolvidas.

alter table public.despesas_loja
  add column if not exists nota_fiscal text,
  add column if not exists atualizado_por uuid references public.perfis(id),
  add column if not exists atualizado_por_nome text;

-- Assinaturas mudam (novo parâmetro) → recria as funções
drop function if exists public.despesas_loja_salvar(uuid, text, text, text, text, date, numeric, date, integer, text);
drop function if exists public.despesas_loja_salvar_rateio(text[], numeric[], text, text, text, text, date, numeric, date, integer, text);

-- Recalcula as parcelas de um lançamento (divisão igual em centavos, resto na última)
create or replace function public.despesas_loja_gerar_parcelas(p_despesa_id uuid, p_valor numeric, p_mes_inicial date, p_qtd int)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_base numeric(14,2); v_mes date := date_trunc('month', p_mes_inicial)::date; i int;
begin
  delete from despesas_loja_parcelas where despesa_id = p_despesa_id;
  v_base := trunc(p_valor / p_qtd, 2);
  for i in 1..p_qtd loop
    insert into despesas_loja_parcelas (despesa_id, numero_parcela, mes_apuracao, valor)
    values (p_despesa_id, i, (v_mes + make_interval(months => i-1))::date,
            case when i = p_qtd then p_valor - v_base*(p_qtd-1) else v_base end);
  end loop;
end $$;
revoke all on function public.despesas_loja_gerar_parcelas(uuid, numeric, date, int) from public, anon, authenticated;

-- Divide o valor entre as lojas (mesma regra do front)
create or replace function public.despesas_loja_calc_rateio(p_n int, p_modo text, p_percentuais numeric[], p_total numeric,
  out o_pcts numeric[], out o_vals numeric[])
language plpgsql immutable set search_path to 'public' as $$
declare v_base numeric(14,2); v_acum numeric(14,2) := 0; v_soma numeric; k int;
begin
  o_vals := '{}';
  if p_modo = 'igual' then
    select array_agg(round(100.0/p_n, 4)) into o_pcts from generate_series(1,p_n);
    v_base := trunc(p_total / p_n, 2);
    for k in 1..p_n loop
      o_vals := o_vals || (case when k = p_n then p_total - v_base*(p_n-1) else v_base end);
    end loop;
  else
    if coalesce(array_length(p_percentuais,1),0) <> p_n then raise exception 'Informe o percentual de cada loja'; end if;
    if exists (select 1 from unnest(p_percentuais) x where x is null or x <= 0) then raise exception 'Todo percentual deve ser maior que zero'; end if;
    select sum(x) into v_soma from unnest(p_percentuais) x;
    if abs(v_soma - 100) > 0.01 then raise exception 'Os percentuais somam %, mas precisam somar 100%%', replace(round(v_soma,2)::text,'.',',') || '%'; end if;
    o_pcts := p_percentuais;
    for k in 1..p_n loop
      if k < p_n then
        o_vals := o_vals || round(p_total * p_percentuais[k] / 100, 2);
        v_acum := v_acum + round(p_total * p_percentuais[k] / 100, 2);
      else
        o_vals := o_vals || (p_total - v_acum);
      end if;
    end loop;
  end if;
  if exists (select 1 from unnest(o_vals) x where x <= 0) then
    raise exception 'O valor é pequeno demais para ser dividido entre essas lojas';
  end if;
end $$;
revoke all on function public.despesas_loja_calc_rateio(int, text, numeric[], numeric) from public, anon, authenticated;

-- Lançamento de uma loja: cria (p_id nulo) ou edita qualquer campo
create function public.despesas_loja_salvar(p_id uuid, p_loja text, p_conta text, p_descricao text, p_fornecedor text,
  p_data date, p_valor_total numeric, p_mes_inicial date, p_qtd_meses integer, p_observacao text, p_nota_fiscal text default null)
returns despesas_loja language plpgsql security definer set search_path to 'public' as $$
declare v public.despesas_loja; v_atual public.despesas_loja; v_nome text;
begin
  if p_valor_total is null or p_valor_total <= 0 then raise exception 'Valor total inválido'; end if;
  if p_qtd_meses is null or p_qtd_meses < 1 or p_qtd_meses > 60 then raise exception 'Quantidade de meses inválida (1 a 60)'; end if;
  if p_mes_inicial is null then raise exception 'Informe o mês de apuração'; end if;
  if coalesce(trim(p_descricao),'') = '' then raise exception 'Informe a descrição da despesa'; end if;
  if not pode_despesas_loja(p_loja) then raise exception 'Sem acesso à loja %', p_loja; end if;
  select nome into v_nome from perfis where id = auth.uid();

  if p_id is null then
    insert into despesas_loja (loja, conta_contabil, descricao, fornecedor, nota_fiscal, data_lancamento, valor_total, qtd_parcelas, observacao, registrado_por, registrado_por_nome)
    values (p_loja, p_conta, trim(p_descricao), nullif(trim(p_fornecedor),''), nullif(trim(p_nota_fiscal),''), coalesce(p_data,current_date),
            round(p_valor_total,2), p_qtd_meses, nullif(trim(p_observacao),''), auth.uid(), v_nome)
    returning * into v;
  else
    select * into v_atual from despesas_loja where id = p_id;
    if v_atual.id is null or not pode_despesas_loja(v_atual.loja) then raise exception 'Lançamento não encontrado ou sem permissão para editar'; end if;
    if v_atual.rateio_id is not null then raise exception 'Este lançamento faz parte de um rateio entre lojas: edite o rateio inteiro.'; end if;
    update despesas_loja set loja=p_loja, conta_contabil=p_conta, descricao=trim(p_descricao), fornecedor=nullif(trim(p_fornecedor),''),
      nota_fiscal=nullif(trim(p_nota_fiscal),''), data_lancamento=coalesce(p_data,data_lancamento), valor_total=round(p_valor_total,2),
      qtd_parcelas=p_qtd_meses, observacao=nullif(trim(p_observacao),''), atualizado_por=auth.uid(), atualizado_por_nome=v_nome
    where id = p_id returning * into v;
  end if;

  perform despesas_loja_gerar_parcelas(v.id, v.valor_total, p_mes_inicial, p_qtd_meses);
  return v;
end $$;

-- Rateio entre lojas: cria (p_rateio_id nulo) ou edita o rateio inteiro (lojas, percentuais, valores e demais campos).
-- Na edição, lojas que continuam mantêm o número do lançamento; lojas retiradas são apagadas; lojas novas ganham lançamento novo.
create function public.despesas_loja_salvar_rateio(p_lojas text[], p_percentuais numeric[], p_modo text, p_conta text, p_descricao text,
  p_fornecedor text, p_data date, p_valor_total numeric, p_mes_inicial date, p_qtd_meses integer, p_observacao text,
  p_nota_fiscal text default null, p_rateio_id uuid default null)
returns setof despesas_loja language plpgsql security definer set search_path to 'public' as $$
declare
  n int := coalesce(array_length(p_lojas,1),0);
  v_total numeric(14,2); v_rateio uuid := coalesce(p_rateio_id, gen_random_uuid());
  v_pcts numeric[]; v_vals numeric[]; v public.despesas_loja; v_nome text; v_id uuid; k int;
begin
  if p_valor_total is null or p_valor_total <= 0 then raise exception 'Valor total inválido'; end if;
  if p_qtd_meses is null or p_qtd_meses < 1 or p_qtd_meses > 60 then raise exception 'Quantidade de meses inválida (1 a 60)'; end if;
  if p_mes_inicial is null then raise exception 'Informe o mês de apuração'; end if;
  if coalesce(trim(p_descricao),'') = '' then raise exception 'Informe a descrição da despesa'; end if;
  if n < 2 then raise exception 'Selecione pelo menos duas lojas para o rateio'; end if;
  if (select count(distinct x) from unnest(p_lojas) x) <> n then raise exception 'Há lojas repetidas no rateio'; end if;
  if p_modo not in ('igual','percentual') then raise exception 'Modo de rateio inválido'; end if;
  for k in 1..n loop
    if not pode_despesas_loja(p_lojas[k]) then raise exception 'Sem acesso à loja %', p_lojas[k]; end if;
  end loop;

  if p_rateio_id is not null then
    if not exists (select 1 from despesas_loja where rateio_id = p_rateio_id) then raise exception 'Rateio não encontrado'; end if;
    if exists (select 1 from despesas_loja where rateio_id = p_rateio_id and not pode_despesas_loja(loja)) then
      raise exception 'Sem permissão para editar este rateio (inclui loja sem acesso)';
    end if;
  end if;

  v_total := round(p_valor_total, 2);
  select o_pcts, o_vals into v_pcts, v_vals from despesas_loja_calc_rateio(n, p_modo, p_percentuais, v_total);
  select nome into v_nome from perfis where id = auth.uid();

  if p_rateio_id is not null then
    delete from despesas_loja where rateio_id = p_rateio_id and loja <> all(p_lojas);
  end if;

  for k in 1..n loop
    v_id := null;
    if p_rateio_id is not null then
      select id into v_id from despesas_loja where rateio_id = p_rateio_id and loja = p_lojas[k];
    end if;
    if v_id is null then
      insert into despesas_loja (loja, conta_contabil, descricao, fornecedor, nota_fiscal, data_lancamento, valor_total, qtd_parcelas, observacao,
                                 registrado_por, registrado_por_nome,
                                 rateio_id, rateio_modo, rateio_percentual, rateio_valor_total, rateio_qtd_lojas)
      values (p_lojas[k], p_conta, trim(p_descricao), nullif(trim(p_fornecedor),''), nullif(trim(p_nota_fiscal),''), coalesce(p_data,current_date),
              v_vals[k], p_qtd_meses, nullif(trim(p_observacao),''), auth.uid(), v_nome,
              v_rateio, p_modo, v_pcts[k], v_total, n)
      returning * into v;
    else
      update despesas_loja set conta_contabil=p_conta, descricao=trim(p_descricao), fornecedor=nullif(trim(p_fornecedor),''),
        nota_fiscal=nullif(trim(p_nota_fiscal),''), data_lancamento=coalesce(p_data,data_lancamento), valor_total=v_vals[k],
        qtd_parcelas=p_qtd_meses, observacao=nullif(trim(p_observacao),''),
        rateio_modo=p_modo, rateio_percentual=v_pcts[k], rateio_valor_total=v_total, rateio_qtd_lojas=n,
        atualizado_por=auth.uid(), atualizado_por_nome=v_nome
      where id = v_id returning * into v;
    end if;
    perform despesas_loja_gerar_parcelas(v.id, v.valor_total, p_mes_inicial, p_qtd_meses);
    return next v;
  end loop;
end $$;

revoke all on function public.despesas_loja_salvar(uuid, text, text, text, text, date, numeric, date, integer, text, text) from public, anon;
revoke all on function public.despesas_loja_salvar_rateio(text[], numeric[], text, text, text, text, date, numeric, date, integer, text, text, uuid) from public, anon;
grant execute on function public.despesas_loja_salvar(uuid, text, text, text, text, date, numeric, date, integer, text, text) to authenticated;
grant execute on function public.despesas_loja_salvar_rateio(text[], numeric[], text, text, text, text, date, numeric, date, integer, text, text, uuid) to authenticated;
