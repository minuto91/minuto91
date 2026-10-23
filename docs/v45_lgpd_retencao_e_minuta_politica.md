# Minuto 91 — V4.5: retenção financeira, LGPD e minuta da Política de Privacidade v1.3

Data: 22/10/2026 · Situação: **proposta operacional e minuta para validação jurídica**. Nada aqui foi implementado como
exclusão irreversível, e nenhum prazo é definitivo: todos os prazos estão marcados **[VALIDAR COM ADVOGADO]**.

---

## 1. O que o banco guarda hoje (levantado no código, migrações 043–047)

| Dado | Onde | Quem vê | O que acontece hoje na exclusão de conta (021/036) |
|---|---|---|---|
| Nome do mensalista com conta | `finance_members.membership_id` → `pelada_memberships.player_name` | Admin e assistentes com permissão financeira (Pelada Premium) | O nome da associação vira **"Aposentado"** (036) |
| Nome de pessoa de fora (pagador externo) | `finance_payers.display_name` (2–60 caracteres) | Idem | Não muda (não tem conta) |
| Observação de pessoa de fora | `finance_payers.notes` (até 200) | Idem | Não muda |
| Observação de mensalista | `finance_members.notes` (até 200) | Idem | Não muda |
| Observação de pagamento | `finance_payments.notes` (até 200) | Idem | Não muda |
| Observação de receita/despesa | `finance_entries.notes` (até 200) | Idem | Não muda |
| Motivo de cancelamento/estorno | `finance_charges.cancel_reason`, `finance_payments.reverse_reason`, `finance_entries.cancel_reason` | Idem | Não muda |
| Autor de cada registro | `created_by`, `cancelled_by`, `reversed_by` → `profiles` | Idem (nome do autor) | Vira vazio (`on delete set null`) quando o perfil é apagado |
| Auditoria (antes/depois) | `finance_events.before_data` / `after_data` (JSON) | Idem | **Não muda**. Contém, por exemplo, o **nome da pessoa** em `monthly_created` (via `finance_member_json`) e em `payer_created`/`payer_updated`, e as observações em `entry_created`/`entry_updated` |
| Autor da auditoria | `finance_events.actor_user_id` | Idem | Vira vazio (`on delete set null`) |
| Permissão financeira | `finance_access` | Admin | V4.5: some sozinha quando a pessoa deixa de ser assistente ativa (047), com registro na auditoria |
| Pessoa de fora "arquivada" | `finance_payers.archived_at` | — | A coluna existe, mas **não há função para arquivar** |

Achados que entram no relatório V4.5 (seção 3, itens L1–L4):

- **L1 (P2)**: depois da exclusão de conta, o nome do ex-mensalista continua em `finance_events.after_data`
  (evento `monthly_created`) e pode aparecer em observações livres. A troca do nome por "Aposentado" na associação
  não alcança essas cópias.
- **L2 (P2)**: pessoa de fora não tem como ser arquivada nem anonimizada pelo app (falta função).
- **L3 (P3)**: observações livres aceitam qualquer texto; não há aviso para não escrever dado sensível.
- **L4 (P3)**: não existe exportação dos próprios dados pela pessoa (LGPD art. 18, II e V); hoje só por pedido no canal
  de privacidade.

## 2. Proposta operacional (para aprovar antes de implementar)

Princípios: não apagar valores contábeis (os totais do caixa não podem mudar), separar **valor** de **identificação**,
preferir **anonimização** a exclusão, registrar tudo na auditoria, e nada irreversível sem aprovação jurídica.

### 2.1 Prazos propostos [VALIDAR COM ADVOGADO]

| Dado | Prazo proposto | Depois do prazo | Base sugerida (a validar) |
|---|---|---|---|
| Movimentações (valores, datas, categorias) | Enquanto a pelada existir | Mantidos (sem identificação depois do item abaixo) | Execução do contrato com o organizador; legítimo interesse do grupo em prestar contas |
| Identificação nas movimentações (nome de pessoa de fora, observações, motivos, nome nos JSON da auditoria) | **5 anos** após a data da movimentação | Anonimizar (substituir por "Pessoa removida" / apagar texto livre) | Prazo usual de cobrança de dívida líquida (CC art. 206 §5º I) — confirmar se se aplica a rateio entre amigos |
| Auditoria (`finance_events`) | Mesmo prazo da movimentação | Mantém tipo, data e valores; anonimiza nomes e textos livres | Prestação de contas |
| Ex-mensalista que excluiu a conta | Na conclusão da exclusão (30 dias, já existente) | Anonimizar o nome nas cópias da auditoria e as observações em que a pessoa é o assunto | Art. 16 LGPD (eliminação após o término do tratamento), com a ressalva do item anterior se houver dívida em aberto |
| Pessoa de fora | Até o admin arquivar, ou 5 anos sem movimentação | Arquivar e, se pedido pelo titular, anonimizar | Idem |
| Pelada Premium expirada | Mantido (decisão V4.3: volta a aparecer quando reativar) | — sugerido: aviso ao admin depois de 24 meses sem Premium e anonimização após 5 anos | Minimização |

### 2.2 Mudanças técnicas propostas (não implementadas na V4.5)

1. `archive_finance_payer(p_payer, p_reason)` e `restore_finance_payer` (reversíveis; o nome continua nos registros).
2. `anonymize_finance_person(p_pelada, p_membership | p_payer, p_reason)` — **irreversível**: troca nome por
   "Pessoa removida" em `finance_payers`, limpa `notes` das linhas da pessoa, e reescreve `person_name`/`name` e `notes`
   nos JSON de `finance_events` daquela pessoa. Valores, datas e status ficam iguais (os totais não mudam). Só admin,
   com motivo, registrado na auditoria. Usar também dentro de `private.purge_account` para o ex-mensalista.
3. Rotina mensal (pg_cron, já existente) que anonimiza a identificação de movimentações com mais de 5 anos.
4. Aviso nos campos de observação: "Não escreva dados sensíveis (saúde, documentos, dados bancários)."
5. Tela "Baixar meus dados" (perfil, peladas, estatísticas, troféus e, para o admin, o CSV do Financeiro).

### 2.3 Atendimento a pedidos dos titulares (procedimento até existir tela)

1. Pedido chega pelo e-mail de privacidade. Confirmar identidade de forma proporcional (resposta pelo e-mail da conta;
   para pessoa de fora, confirmação pelo admin da pelada).
2. Registrar o pedido (data, tipo, titular, pelada) numa planilha controlada.
3. **Acesso/portabilidade**: exportar perfil, peladas, estatísticas, troféus e, se a pessoa for pagadora, as
   movimentações em que aparece (o admin gera o CSV do Financeiro filtrado).
4. **Correção**: o admin corrige pelo próprio Financeiro (fica na auditoria).
5. **Eliminação**: conta → fluxo de exclusão já existente (30 dias). Pessoa de fora → arquivar; anonimizar quando a
   função existir (até lá, o admin edita o nome para "Pessoa removida" e apaga as observações; o histórico de auditoria
   anterior continua com o nome — informar isso ao titular e ao advogado).
6. Responder em até **15 dias** (art. 19, II, LGPD — confirmar) com o que foi feito e o que foi mantido e por quê.

---

## 3. Minuta — Política de Privacidade v1.3 (alterações sobre a v1.2)

> Minuta para revisão jurídica. Só as seções que mudam. O restante da v1.2 continua igual. Ao publicar, trocar
> `app/src/lib/legalText.ts` e `private.app_config.legal_versions` juntos (procedimento da V4.2).

**Cabeçalho**: "Versão 1.3 — Minuta para revisão jurídica (alinhada aos Termos de Uso v1.1)". "Última atualização: [DATA]".

**3.2-A (novo) — Dados do Financeiro da pelada (Pelada Premium)**
"Quando o organizador usa o Financeiro da Pelada Premium, o aplicativo registra o que ele lançar: nomes de quem paga
(jogadores da pelada ou pessoas de fora, identificadas só pelo nome), valores devidos e pagos, datas, forma de pagamento
informada, receitas e despesas da pelada, observações e motivos de cancelamento ou estorno, além de quem fez cada
registro e quando. **O Minuto 91 não processa pagamentos**: não coleta dados de cartão, conta bancária ou chave Pix; o
Financeiro é um livro-caixa preenchido pelo organizador."

**6-A (novo) — Quem vê o Financeiro**
"Somente o administrador da pelada e os assistentes que ele autorizar expressamente veem o Financeiro, e só enquanto a
pelada tiver a Pelada Premium. Jogadores comuns não veem dados financeiros de ninguém. Quando um assistente deixa de ser
assistente ou sai da pelada, a autorização é retirada automaticamente."

**4 — Finalidades (acrescentar)**
"• Permitir que o organizador controle cobranças, pagamentos, receitas e despesas da pelada e preste contas ao grupo."
Base legal sugerida: execução do contrato com o organizador e legítimo interesse do grupo [VALIDAR COM ADVOGADO].

**Observações livres (novo parágrafo em 3.2-A)**
"Os campos de observação devem conter apenas o necessário para o controle do caixa. Não registre dados sensíveis
(saúde, documentos, dados bancários). O organizador é responsável pelo que escreve nesses campos."

**11 — Retenção (substituir o item "Dados financeiros")**
"• Dados do Financeiro: os valores, datas e categorias são mantidos enquanto a pelada existir, para que os totais do
caixa não mudem. Nomes de pessoas, observações e motivos ligados a cada movimentação são mantidos por até **5 anos**
após a data da movimentação [VALIDAR COM ADVOGADO] e depois anonimizados. Se a Pelada Premium deixar de estar ativa,
os registros continuam guardados (sem acesso) e voltam a aparecer se a assinatura for reativada."
"• Histórico de alterações do Financeiro (auditoria): mesmo prazo e mesma regra."

**12 — Exclusão de conta (acrescentar)**
"Se você constar no Financeiro de uma pelada, seu nome passa a aparecer como "Aposentado" ou "Pessoa removida". Os
valores lançados podem ser mantidos para a prestação de contas do grupo, sem identificar você, salvo se houver obrigação
legal ou valor em aberto que justifique a guarda pelo prazo do item 11 [VALIDAR COM ADVOGADO]."

**13 — Direitos (acrescentar)**
"Pessoas de fora que aparecem no Financeiro de uma pelada (sem conta no aplicativo) também podem pedir acesso,
correção ou eliminação pelo e-mail de privacidade. Poderemos confirmar o pedido com o organizador da pelada."

**15 — Notificações (ajustar)**
"Você pode desligar, em Minha conta, cada categoria de aviso: nova partida e votação aberta, lembrete de votação,
resultado publicado, premiações e conquistas, e avisos importantes da pelada. Avisos sobre transferência de conta são
sempre enviados, por segurança. Não enviamos avisos sobre o Financeiro."

**8 — Cartas, rankings e Sala de Troféus (acrescentar)**
"A Sala de Troféus mostra as premiações oficiais Craque da Partida, Rei do Mês e Bola Murcha. Quem vê o seu perfil
segue a sua configuração de privacidade; para quem não joga na mesma pelada, aparecem só o troféu, a pelada e a data."
[VALIDAR COM ADVOGADO e com o fundador: Bola Murcha visível no perfil — decisão pendente desde a V4.4]

### Pontos para o advogado

1. Prazo de 5 anos para a identificação nas movimentações (CC art. 206 §5º I se aplica a rateio informal?).
2. Base legal para tratar nome de **pessoa de fora** lançado pelo organizador (legítimo interesse do organizador?) e
   quem é controlador desses dados (o Minuto 91, o organizador, ou ambos).
3. Guarda do nome em auditoria após a exclusão de conta, se houver valor em aberto.
4. Prazo de resposta aos titulares e forma de confirmar a identidade de pessoa de fora.
5. Bola Murcha visível na Sala de Troféus do perfil.
