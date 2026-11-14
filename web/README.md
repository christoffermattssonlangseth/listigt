# Listigt

Inköpslista med basvaror och EAN-scanning. Webbapp (PWA) – lägg till på hemskärmen i mobilen.

## Köra lokalt

    python3 -m http.server 8000

Utan Firebase-inställningar sparas allt bara på enheten.

## Synkning mellan telefoner (Firebase, gratis)

1. Skapa ett projekt på https://console.firebase.google.com
2. **Firestore Database** → Skapa databas (region t.ex. `eur3`, produktionsläge).
3. **Projektinställningar → Dina appar → Webb (</>)** → registrera app, kopiera `firebaseConfig`
   och klistra in i `config.js`.
4. Publicera (ger https, vilket kameran kräver):

       npx firebase-tools login
       npx firebase-tools use --add      # välj projektet
       npx firebase-tools deploy

5. Öppna `https://<projekt>.web.app` på telefonen → **Dela** → skicka länken till den andra telefonen.

Listan identifieras av ett långt slumpat id i delningslänken; den som har länken kan läsa och ändra listan.
