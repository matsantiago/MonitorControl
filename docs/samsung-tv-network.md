# Brilho e volume de TVs Samsung pela rede

O MonitorControl pode usar a rede local para controlar uma TV Samsung associada à tela do Mac. A TV continua recebendo imagem pelo HDMI. Na **QN50QN90BAGXZD**, testamos leitura, ajuste e restauração do **brilho físico** e do **volume**, além do controle de volume por teclas do controle remoto virtual.

## Configuração na QN90B

1. Conecte a TV e o Mac à mesma rede local. A TV pode usar Wi-Fi ou Ethernet e manter a configuração de IP automática.
2. Na TV, abra **Todas as Configurações → Conexão → Rede → Configurações Especializadas**. Ative **Ligar com Dispositivo Móvel** e depois **Controle Remoto IP**. Volte à entrada HDMI do Mac.
3. No MonitorControl, abra **Ajustes → Telas**. O app testa o brilho DDC da tela Samsung. Se a tela estiver sem resposta por DDC, o app procura TVs Samsung na rede local. Na linha **QBQ90**, clique em **Configurar TV…**, selecione a unidade e clique em **Conectar**.
4. Escolha **Parear brilho e volume…** e clique em **Parear**. Se a TV mostrar uma solicitação de controle IP, selecione **Permitir**. No macOS, permita o acesso do MonitorControl à rede local se houver uma solicitação.
5. Aguarde o status **Brilho e volume conectados** na linha da TV e use os sliders na barra de menus. Para confirmar o brilho físico, observe o valor **Brilho** nas configurações de imagem da TV ao mover o slider do Mac. O app converte a escala exibida de 0–100% para os níveis de 0 a 50 da Samsung. O volume usa os níveis de 0 a 100 da TV. A escala do brilho se refere à configuração da TV, e a luminância efetiva depende do modo de imagem e do conteúdo.

O menu da Samsung e a disponibilidade dos comandos podem variar conforme o firmware, a região e a entrada ativa. [Guia de controle IP da Samsung](https://image-us.samsung.com/SamsungUS/samsungbusiness/tv-ci-resources/Samsung-IP-Control.pdf) · [Lista de comandos de imagem e som](https://www.hillresi.com/wp-content/uploads/2022/01/2020_IP_command_list.pdf)

## Teclas do Mac e volume alternativo

- Em **Ajustes → Teclado** do MonitorControl, escolha as teclas de mídia ou atalhos personalizados e o destino de cada ajuste. Para direcionar as teclas de volume pela saída de áudio, selecione a TV como saída de som no macOS. Quando o áudio estiver nos AirPods, use os sliders do MonitorControl ou atalhos personalizados direcionados à tela da TV.
- Se **Controle Remoto IP** estiver indisponível, escolha **Parear apenas volume…**. Aprove o MonitorControl na TV, se solicitado. O menu oferece aumentar, diminuir e silenciar o volume, e as teclas podem enviar os mesmos botões. Nessa configuração, o brilho continua disponível por escurecimento de software até o pareamento do brilho físico.
- Para remover a associação no Mac, marque **Mostrar ajustes avançados** em **Telas** e abra **Gerenciar vínculo da TV… → Esquecer TV**. A TV pode manter sua própria lista de aparelhos autorizados.

## Quando o endereço IP mudar

O app usa SSDP/UPnP para localizar TVs Samsung que anunciam o serviço RenderingControl. A associação permanece com o UUID do aparelho. O IP salvo serve como endereço inicial. Se ele ficar inacessível ou responder com outra identidade, o MonitorControl busca o UUID original, valida a descrição do aparelho e salva o endereço novo. A descoberta volta a funcionar quando a TV anunciar o serviço após sair do repouso. O app guarda os tokens e os certificados de cada pareamento nas Chaves do macOS.

| Sintoma | O que verificar |
| --- | --- |
| A TV não aparece na busca | Mantenha a TV ligada e confira se o Mac e a TV estão na mesma rede sem isolamento entre aparelhos. No macOS, veja **Ajustes do Sistema → Privacidade e Segurança → Rede Local**. |
| A TV aparece, mas o pareamento dos sliders falha | Confira **Ligar com Dispositivo Móvel** e **Controle Remoto IP** e deixe a entrada HDMI do Mac ativa ao parear. |
| O volume responde na TV e o teclado muda o volume de outro aparelho | Confira o destino de volume em **Ajustes → Teclado** do MonitorControl e a saída de som ativa no macOS. |
| O app pede novo pareamento | Use **Configurar TV…** se a TV tiver revogado o token ou alterado o certificado. Quando a TV estiver fora da rede, o app tenta reencontrá-la automaticamente. |

## Implementação e verificação

O transporte HTTPS na porta TCP 1516 utiliza `backlightControl`, `directVolumeControl` e, quando aceito pela TV, `muteControl`. O pareamento opcional para volume usa o WebSocket seguro na porta TCP 8002. SSDP usa UDP 1900. A descoberta desconsidera anúncios cujo endereço de descrição diverge do IP de origem, e o controle autenticado confirma o certificado do pareamento antes de enviar o token. Leituras e escritas ocorrem fora da fila da interface. O app agrupa movimentos sucessivos dos sliders e confirma os valores pela leitura da TV. [Referência de protocolo](https://github.com/TheFab21/ha-samsungtv-smart/blob/master/IP_Control_Protocol_Reference.md) · [Biblioteca de referência para WebSocket](https://github.com/xchwarze/samsung-tv-ws-api)

Para verificar a descoberta após uma mudança real de IP, mantenha o vínculo no MonitorControl e deixe a TV receber um novo endereço via DHCP. Quando a TV ficar online, abra **Gerenciar vínculo da TV…** nos ajustes avançados, confira o endereço atualizado e teste os controles. Com duas telas externas, altere o brilho de cada uma pelo menu para conferir o vínculo.

Para compilar o fork, siga as [instruções de compilação e assinatura local](ddc-service-matching.md#compilação-local). Se estiver compilando alterações ainda fora de um commit, copie a árvore de trabalho para a pasta temporária em vez de usar `git archive HEAD`.
