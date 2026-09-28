# PC Remote

Télécommande iPhone pour un PC Windows sur le même réseau local.

## Fonctions

- État du PC : en ligne / hors ligne
- Éteindre Windows
- Redémarrer Windows
- Allumer le PC avec Wake-on-LAN
- Commandes signées en HMAC-SHA256
- Agent Windows lancé automatiquement au démarrage
- Pare-feu Windows limité au réseau local

## Installation Windows

Ouvrir PowerShell en administrateur :

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\Install-PCRemote.ps1
```

L'installateur affiche :
- IP
- PORT
- MAC
- CLE

Ne jamais publier la CLE.

## Réglages iPhone

Dans l'application, renseigner :
- IP du PC
- port (8765 par défaut)
- adresse MAC
- broadcast du réseau
- clé secrète

Exemple de broadcast pour un réseau /24 : `192.168.1.255`.

## Wake-on-LAN

Sur une MSI B650 Gaming Plus WiFi :
- BIOS -> Settings -> Advanced -> Power Management Setup -> ErP Ready = Disabled
- BIOS -> Settings -> Advanced -> Wake Up Event Setup -> Resume By PCI-E/Networking Device = Enabled
- Windows -> carte Ethernet -> Wake on Magic Packet = Enabled

L'Ethernet est recommandé.

## Générer l'IPA sans Mac

GitHub -> Actions -> **Build unsigned IPA** -> **Run workflow**.

Télécharger ensuite l'artefact `PCRemote-unsigned-ipa`.

L'IPA est non signé. Il faut le signer/sideload avec son propre compte Apple via AltStore, SideStore ou un outil équivalent.

## Sécurité

Ne pas ouvrir le port 8765 directement sur Internet.

Pour une future utilisation depuis la 4G/5G ou hors du domicile, utiliser un VPN privé tel que Tailscale plutôt qu'une redirection de port publique.
