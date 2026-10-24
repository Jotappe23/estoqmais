# EstoqMais 1.0 — edição otimizada

https://jotappe23.github.io/estoqmais/

Controle de compras, fornecedores, projeções e relatórios. Idealização e criação: João Pedro do Nascimento Silva.

## Otimização

- Salvamentos incrementais por registro com revisão, repetição segura e isolamento por conta.
- Verificação leve da revisão a cada 90 segundos com a página visível.
- Compras carregadas por mês; 20 pedidos por página.
- Histórico recente com diferenças reversíveis. Formato anterior preservado durante a migração.
- Fotos compactadas até 1600 pixels quando o resultado for menor. PDF original preservado.
- Painel de uso com estimativas dos conteúdos da conta e anexos.
- Comparação entre meses/anos, pagamentos manuais, possíveis duplicatas e arquivos anuais.

## Uso

A estrutura otimizada deste projeto já foi configurada. Atualize todos os PCs. O primeiro acesso migra a conta preservando o formato anterior. Sem internet, estão disponíveis os cadastros e o mês carregado neste PC. Exporte um backup completo para guardar todos os períodos. JSON não inclui os arquivos anexados. Arquivar organiza sem apagar ou liberar espaço.

Consulte OTIMIZACAO-E-USO.txt. Scripts SQL são referência; não execute a configuração antiga para atualizar. O pacote de PC e a página pública não incluem registros pessoais, que são carregados após autenticação no Supabase.

## Organização visual — 24/10/2026

Menu agrupado por gestão, análises e ferramentas. Compras possui áreas separadas para Pedidos, Resumo do mês e Pagamentos. Os produtos de cada pedido são expansíveis, os filtros ficam reunidos e as ações de exclusão estão em Mais ações. Cadastro de fornecedores e comparação de preços também possuem áreas próprias.
