# Как собрать в PDF с Mermaid схемами (Linux)
pandoc TensoMLib_Architecture.md \
  -o TensoMLib_Architecture.pdf \
  --pdf-engine=xelatex \
  -V geometry:margin=2cm \
  -V papersize=a4 \
  -V lang=ru \
  -V mainfont="NimbusRoman-Regular" \
  -V monofont="Nimbus Mono PS" \
  -V header-includes="\usepackage{microtype}\usepackage{booktabs}\usepackage{longtable}" \
  --filter=mermaid-filter