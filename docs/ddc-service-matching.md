# Associação de monitores a canais DDC no Apple Silicon

O macOS pode listar vários serviços `DCPAVServiceProxy` perto do mesmo framebuffer. A ordem desses serviços varia com a topologia de vídeo. Um proxy inativo pode herdar os dados de identificação do framebuffer e receber a maior pontuação mesmo quando outro proxy é o que comunica com a tela.

| Situação | Comportamento |
| --- | --- |
| Vários proxies para uma tela | O app lê o bloco base do EDID de cada proxy externo, valida seu cabeçalho e checksum e procura uma correspondência única de fabricante, produto e número de série. |
| Mais de uma tela, inclusive do mesmo modelo | O número de série ajuda a distinguir as telas. Cada proxy só pode ser atribuído uma vez e um proxy cujo EDID identifica outra tela online fica fora da busca. |
| EDID ilegível, alterado ou com número de série ausente ou repetido | A pontuação baseada no registro do macOS continua disponível. Um EDID compatível desempata proxies que obtêm a mesma pontuação. |
| Retomada do repouso ou mudança de conexão | O app refaz a detecção e substitui as referências antigas. As leituras de EDID usam a mesma fila das operações DDC. |
| EDID legível, mas sem resposta a comandos DDC/CI | O EDID confirma a identidade da tela. Cada controle ainda depende de suporte no monitor e na conexão. |

A seleção usa as identidades apresentadas pelos dispositivos, de forma independente da marca. A leitura direta do EDID tem como referência o [m1ddc](https://github.com/waydabber/m1ddc/pull/61).

## Compilação local

Com o Xcode completo instalado, execute a partir do repositório. A cópia temporária preserva o checkout, pois a compilação altera os plists do projeto.

```sh
build_dir=$(mktemp -d)
git archive HEAD | tar -x -C "$build_dir"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "$build_dir/MonitorControl.xcodeproj" -scheme MonitorControl \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$build_dir/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile MACOSX_DEPLOYMENT_TARGET=12.0 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build
```

O Sparkle fornecido pelo projeto tem assinatura própria. Para abrir a compilação ad hoc com o Hardened Runtime, assine o app local com a permissão de carregar essa biblioteca. Preserve as assinaturas originais dos componentes do Sparkle. [Documentação da Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)

```sh
app="$build_dir/DerivedData/Build/Products/Release/MonitorControl.app"
cat > "$build_dir/local.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
PLIST
codesign --force --sign - --options runtime \
  --entitlements "$build_dir/local.entitlements" "$app"
codesign --verify --deep --strict "$app"
```

Ao substituir a instalação oficial, feche o MonitorControl e guarde uma cópia do app e das preferências. A assinatura local pode exigir uma nova autorização para as teclas de mídia em **Ajustes do Sistema → Privacidade e Segurança → Acessibilidade**. Desative a verificação automática de atualizações na instalação local e recompile o fork quando quiser atualizá-lo.

Para voltar ao app oficial, feche o fork, restaure o app e importe o backup das preferências antes de abri-lo. O app oficial pode apagar as preferências ao detectar um número de build mais novo. Use `defaults import app.monitorcontrol.MonitorControl /caminho/para/preferences.plist`.

## Verificação

Com **Use hardware DDC control** ativo nas preferências da tela, mude o brilho pelo menu do app e confira o valor no menu físico do monitor. Repita com duas telas externas ligadas e após reconectar uma delas. Em monitores do mesmo modelo, confirme que cada controle atua no painel correspondente.
