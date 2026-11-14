# Diagramas

| Arquivo | O que mostra |
|---|---|
| `arquitetura.mmd` | As três camadas: `modules/` → `environments/` → AWS, com os dois states |
| `pipeline.mmd` | O gitflow: o que roda em cada evento, e onde fica o gate de aprovação |
| `monitoramento.mmd` | Os três caminhos de alvo até o Prometheus, e daí a Grafana e alertas |
| `image.png` | Diagrama original do desafio. Mantido como registro do ponto de partida: `apply` direto no push, sem revisão e sem gate |

## Por que Mermaid e não imagem

Os três diagramas estão embutidos no [README raiz](../README.md) e o GitHub os
renderiza nativamente. O fonte é texto, então:

- aparece como diff legível num Pull Request — alteração em PNG é binário opaco;
- edita-se em qualquer editor, sem precisar abrir o drawio;
- não sai de sincronia com o código por esquecimento de reexportar a imagem.

## Gerar PNG ou SVG

Se precisar dos arquivos de imagem (para slide, documento, apresentação):

```bash
npx -y @mermaid-js/mermaid-cli -i arquitetura.mmd   -o arquitetura.png
npx -y @mermaid-js/mermaid-cli -i pipeline.mmd      -o pipeline.png
npx -y @mermaid-js/mermaid-cli -i monitoramento.mmd -o monitoramento.svg
```

O `mermaid-cli` baixa o Chromium na primeira execução (algumas centenas de
MB), por isso o render não faz parte do fluxo normal do projeto.

## Conferir a sintaxe

O editor online [mermaid.live](https://mermaid.live) valida e pré-visualiza
colando o conteúdo do `.mmd`.
