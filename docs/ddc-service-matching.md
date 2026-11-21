# Associação de monitores a canais DDC no Apple Silicon

O macOS pode listar vários serviços `DCPAVServiceProxy` perto do mesmo framebuffer. A ordem desses serviços varia com a topologia de vídeo. Um proxy inativo pode herdar os dados de identificação do framebuffer e receber a maior pontuação mesmo quando outro proxy é o que comunica com a tela.

| Situação | Comportamento |
| --- | --- |
| Vários proxies para uma tela | O app lê o bloco base do EDID de cada proxy externo, valida seu cabeçalho e checksum e procura uma correspondência única de fabricante, produto e número de série. |
| Mais de uma tela, inclusive do mesmo modelo | O número de série ajuda a distinguir as telas. Cada proxy só pode ser atribuído uma vez e um proxy cujo EDID identifica outra tela online fica fora da busca. |
| EDID ilegível, alterado ou com número de série ausente ou repetido | A pontuação baseada no registro do macOS continua disponível. Um EDID compatível desempata proxies que obtêm a mesma pontuação. Uma resposta de dispositivo removido descarta o proxy mesmo que ainda tenha nome ou EDID em cache. |
| Retomada do repouso ou mudança de conexão | O app refaz a detecção e substitui as referências antigas. As leituras de EDID usam a mesma fila das operações DDC. |
| EDID legível, mas sem resposta a comandos DDC/CI | O EDID confirma a identidade da tela. Cada controle ainda depende de suporte no monitor e na conexão. |

A seleção usa as identidades apresentadas pelos dispositivos, de forma independente da marca. A leitura direta do EDID tem como referência o [m1ddc](https://github.com/waydabber/m1ddc/pull/61).


Quando o canal de controle falha, o app busca novamente os serviços em segundo plano. A primeira tentativa acontece após dois segundos. O intervalo dobra até um minuto enquanto a falha persiste. Se o macOS publicar um novo canal, o app antecipa a busca. A janela indica a reconexão e o botão **Atualizar** antecipa a próxima tentativa. O app só volta a usar um canal após receber uma leitura DDC válida da tela correspondente. Uma nova configuração de telas invalida os resultados da configuração anterior.

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

Na primeira compilação local, configure o certificado do MonitorControl nas Chaves. Confirme a solicitação do macOS para confiar no certificado para assinatura de código da sua conta.

```sh
python3 scripts/setup-macos-signing.py
scripts/sign-local-app.sh "$build_dir/DerivedData/Build/Products/Release/MonitorControl.app"
```

Use o mesmo certificado em cada compilação. O script assina o app e o auxiliar de início de sessão e preserva as assinaturas do Sparkle. A identidade fica configurada em `~/Library/Application Support/MonitorControl/Signing/` e a chave privada permanece nas Chaves. [Identidade de código no macOS](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)

Se as Chaves pedirem que você autorize o `codesign` a usar **MonitorControl Personal Signing**, escolha **Sempre Permitir** para reutilizar essa autorização nas próximas compilações.

Ao substituir uma instalação com outra assinatura, feche o MonitorControl e guarde uma cópia do app e das preferências. O macOS pode pedir as permissões novamente na troca de identidade. Para a permissão de Rede Local, a Apple recomenda usar um certificado emitido pela Apple. [Privacidade de Rede Local no macOS](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

Para atualizar a instalação local, substitua `/Applications/MonitorControl.app` sempre com o mesmo certificado. Guarde as versões anteriores em arquivos compactados para evitar que o macOS registre outras cópias com o mesmo identificador. O app solicita Acessibilidade ao escolher as teclas de mídia nas preferências de teclado ou ao clicar no botão de autorização durante a configuração inicial. [Identidade de código no macOS](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)

Para voltar ao app oficial, feche o fork, restaure o app e importe o backup das preferências antes de abri-lo. O app oficial pode apagar as preferências ao detectar um número de build mais novo. Use `defaults import app.monitorcontrol.MonitorControl /caminho/para/preferences.plist`.

## Verificação

Com **Use hardware DDC control** ativo nas preferências da tela, mude o brilho pelo menu do app e confira o valor no menu físico do monitor. Repita com duas telas externas ligadas e após reconectar uma delas. Em monitores do mesmo modelo, confirme que cada controle atua no painel correspondente.
