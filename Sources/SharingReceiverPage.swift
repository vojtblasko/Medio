import Foundation

/// Self-contained receiver: no analytics, external scripts, fonts, or cloud requests.
enum SharingReceiverPage {
    static var html: String {
        """
        <!doctype html><html lang="en"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>Medio</title><style>
        :root{color-scheme:light dark;font:17px -apple-system,BlinkMacSystemFont,sans-serif;background:#111;color:#fff}
        body{max-width:440px;margin:0 auto;padding:48px 24px}h1{font-size:36px;margin-bottom:8px}
        p{line-height:1.5;color:#bbb}input,button{font:inherit;border-radius:16px;padding:16px;box-sizing:border-box;width:100%;margin:8px 0}
        input{background:#242424;color:white;border:1px solid #555;letter-spacing:.25em;text-align:center}
        button{background:#eee;color:#111;border:0;font-weight:600;cursor:pointer}button:disabled{opacity:.45}
        audio{width:100%;margin:20px 0}small{color:#aaa;line-height:1.5;display:block}#title{overflow-wrap:anywhere}
        [hidden]{display:none!important}
        </style><body><h1>Medio</h1><p id="intro"></p>
        <form id="join"><label for="code" id="codeLabel"></label><input id="code" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="off" required><button id="connect"></button></form>
        <section id="player" hidden><h2 id="title"></h2><p id="artist"></p><button id="listen"></button><audio id="audio" controls playsinline preload="none"></audio><button id="disconnect"></button></section>
        <p id="status" role="status" aria-live="polite"></p><small id="note"></small>
        <script>
        'use strict';
        const translations={
          en:{intro:'Listen together on your Wi-Fi.',code:'Access code',connect:'Connect',listen:'Listen',disconnect:'Disconnect',wrong:'Incorrect code. Please try again.',busy:'Too many attempts. Wait a minute and try again.',ended:'Sharing stopped or the host is unavailable.',ready:'Tap Listen to begin.',wait:'Waiting for a song…',blocked:'Tap Listen to resume playback.',unsupported:'This audio format cannot play in this browser.',note:'Connect your headphones or speaker to this device. Keep this page open. Playback follows Medio, with some delay. Use only audio you have permission to share.'},
          cs:{intro:'Poslouchejte společně přes Wi-Fi.',code:'Přístupový kód',connect:'Připojit',listen:'Poslouchat',disconnect:'Odpojit',wrong:'Nesprávný kód. Zkuste to znovu.',busy:'Příliš mnoho pokusů. Počkejte minutu a zkuste to znovu.',ended:'Sdílení skončilo nebo hostitel není dostupný.',ready:'Začněte klepnutím na Poslouchat.',wait:'Čekání na skladbu…',blocked:'Pokračujte klepnutím na Poslouchat.',unsupported:'Tento zvukový formát nelze v prohlížeči přehrát.',note:'Připojte sluchátka nebo reproduktor k tomuto zařízení. Nechte stránku otevřenou. Přehrávání sleduje Medio s mírným zpožděním. Sdílejte jen zvuk, k jehož sdílení máte oprávnění.'},
          de:{intro:'Gemeinsam über WLAN hören.',code:'Zugangscode',connect:'Verbinden',listen:'Anhören',disconnect:'Trennen',wrong:'Falscher Code. Bitte erneut versuchen.',busy:'Zu viele Versuche. Bitte eine Minute warten.',ended:'Die Freigabe wurde beendet oder das Gerät ist nicht erreichbar.',ready:'Zum Starten auf Anhören tippen.',wait:'Warten auf einen Titel…',blocked:'Zum Fortsetzen auf Anhören tippen.',unsupported:'Dieses Audioformat kann in diesem Browser nicht abgespielt werden.',note:'Kopfhörer oder Lautsprecher mit diesem Gerät verbinden. Diese Seite geöffnet lassen. Die Wiedergabe folgt Medio mit etwas Verzögerung. Nur Audio teilen, für das du die nötigen Rechte hast.'},
          fr:{intro:'Écoutez ensemble sur votre Wi-Fi.',code:'Code d’accès',connect:'Se connecter',listen:'Écouter',disconnect:'Se déconnecter',wrong:'Code incorrect. Réessayez.',busy:'Trop de tentatives. Patientez une minute.',ended:'Le partage est arrêté ou l’appareil hôte est indisponible.',ready:'Touchez Écouter pour commencer.',wait:'En attente d’un morceau…',blocked:'Touchez Écouter pour reprendre.',unsupported:'Ce format audio ne peut pas être lu dans ce navigateur.',note:'Connectez votre casque ou enceinte à cet appareil. Gardez cette page ouverte. La lecture suit Medio avec un léger décalage. Partagez uniquement les fichiers audio que vous êtes autorisé à partager.'}
        };
        translations['fr-ca']={...translations.fr,intro:'Écoutez ensemble sur votre Wi-Fi.',wait:'En attente d’une chanson…',note:'Connectez vos écouteurs ou votre haut-parleur à cet appareil. Gardez cette page ouverte. La lecture suit Medio avec un léger décalage. Partagez uniquement les fichiers audio que vous êtes autorisé à partager.'};
        translations.bg={intro:'Слушайте заедно през Wi-Fi.',code:'Код за достъп',connect:'Свързване',listen:'Слушане',disconnect:'Прекъсване',wrong:'Неправилен код. Опитайте отново.',busy:'Твърде много опити. Изчакайте минута.',ended:'Споделянето е спряно или хостът е недостъпен.',ready:'Натиснете Слушане, за да започнете.',wait:'Изчакване на песен…',blocked:'Натиснете Слушане, за да продължите.',unsupported:'Този аудио формат не се поддържа от браузъра.',note:'Свържете слушалките или тонколоната си с това устройство. Оставете страницата отворена. Възпроизвеждането следва Medio с известно закъснение. Споделяйте само аудио, за което имате разрешение.'};
        translations.sk={intro:'Počúvajte spolu cez Wi-Fi.',code:'Prístupový kód',connect:'Pripojiť',listen:'Počúvať',disconnect:'Odpojiť',wrong:'Nesprávny kód. Skúste to znova.',busy:'Príliš veľa pokusov. Počkajte minútu.',ended:'Zdieľanie sa skončilo alebo hostiteľ nie je dostupný.',ready:'Začnite klepnutím na Počúvať.',wait:'Čaká sa na skladbu…',blocked:'Pokračujte klepnutím na Počúvať.',unsupported:'Tento formát zvuku sa v prehliadači nedá prehrať.',note:'Pripojte slúchadlá alebo reproduktor k tomuto zariadeniu. Nechajte stránku otvorenú. Prehrávanie sleduje Medio s určitým oneskorením. Zdieľajte iba zvuk, na ktorý máte oprávnenie.'};
        const lang=(navigator.languages||[navigator.language]).flatMap(x=>[x.toLowerCase(),x.split('-')[0].toLowerCase()]).find(x=>translations[x])||'en', t=translations[lang];
        document.documentElement.lang=lang;
        const el=id=>document.getElementById(id), audio=el('audio');
        for(const [id,key] of Object.entries({intro:'intro',codeLabel:'code',connect:'connect',listen:'listen',disconnect:'disconnect',note:'note'}))el(id).textContent=t[key];
        let token='', currentTrack='', latest=null, following=false, generation=0, failures=0, playAttempt=0;
        function requestSignal(ms){const controller=new AbortController();setTimeout(()=>controller.abort(),ms);return controller.signal;}
        const message=text=>{el('status').textContent=text;};
        function pauseAudio(){playAttempt++;audio.pause();}
        function stop(){generation++;token='';currentTrack='';latest=null;following=false;pauseAudio();audio.removeAttribute('src');audio.load();el('player').hidden=true;el('join').hidden=false;}
        el('disconnect').onclick=()=>{stop();message('');};
        el('join').onsubmit=async event=>{
          event.preventDefault();el('connect').disabled=true;
          try{
            const response=await fetch('/join',{method:'POST',headers:{'Content-Type':'text/plain'},body:el('code').value,cache:'no-store',signal:requestSignal(8000)});
            if(!response.ok){message(response.status===429?t.busy:t.wrong);return;}
            token=(await response.json()).token;el('code').value='';el('join').hidden=true;el('player').hidden=false;failures=0;message(t.ready);poll(++generation);
          }catch{message(t.ended);}finally{el('connect').disabled=false;}
        };
        function align(state,force=false){
          if(!Number.isFinite(state.position))return;
          const elapsed=state.playing&&state.receivedAt?(performance.now()-state.receivedAt)/1000:0;
          const target=Math.max(0,state.position+elapsed), drift=target-audio.currentTime;
          // Correct small clock differences gradually instead of repeatedly flushing the buffer.
          if(force||Math.abs(drift)>3){try{audio.currentTime=target;}catch{}audio.playbackRate=1;}
          else audio.playbackRate=state.playing&&Math.abs(drift)>.15?Math.max(.97,Math.min(1.03,1+drift*.03)):1;
        }
        async function play(){
          const attempt=++playAttempt,run=generation,track=currentTrack;
          const stale=()=>attempt!==playAttempt||run!==generation||track!==currentTrack;
          try{await audio.play();if(stale())return;el('listen').hidden=true;message('');}
          catch{if(stale())return;message(t.blocked);el('listen').hidden=false;}
        }
        el('listen').onclick=()=>{
          if(!latest?.track){message(t.wait);return;}
          following=true;align(latest,true);el('listen').hidden=true;
          // play() is called directly inside the tap event, as required by Safari.
          play();
        };
        audio.addEventListener('loadedmetadata',()=>{if(latest)align(latest,true);});
        audio.addEventListener('error',()=>{if(token&&currentTrack){message(t.unsupported);el('listen').hidden=false;}});
        async function poll(run){
          if(!token||run!==generation)return;
          try{
            const requestedAt=performance.now();
            const response=await fetch('/state',{headers:{Authorization:'Bearer '+token},cache:'no-store',signal:requestSignal(5000)});
            if(!response.ok)throw new Error('session');
            const state=await response.json();if(run!==generation)return;
            state.receivedAt=performance.now();
            if(state.playing)state.position+=Math.min(1,(state.receivedAt-requestedAt)/2000);
            failures=0;latest=state;el('title').textContent=state.title||t.wait;el('artist').textContent=state.artist;
            if(state.track!==currentTrack){
              pauseAudio();currentTrack=state.track||'';
              if(currentTrack){audio.src='/audio/'+encodeURIComponent(currentTrack)+'?token='+encodeURIComponent(token);audio.load();}
              else{audio.removeAttribute('src');audio.load();}
              el('listen').hidden=following;
            }
            if(!state.track){message(state.message||t.wait);}
            else if(following){align(state);if(state.playing){if(audio.paused&&!audio.ended)play();else if(audio.ended){align(state);play();}}else{pauseAudio();audio.playbackRate=1;el('listen').hidden=true;message('');}}
            else message(t.ready);
          }catch{
            if(run!==generation)return;
            // Do not leave the receiver playing a buffered file after the host disappears.
            pauseAudio();if(++failures>=3){stop();message(t.ended);return;}message(t.ended);
          }
          if(run===generation)setTimeout(()=>poll(run),750);
        }
        const scannedCode=new URLSearchParams(location.hash.slice(1)).get('code');
        if(scannedCode&&/^[0-9]{6}$/.test(scannedCode)){
          el('code').value=scannedCode;history.replaceState(null,'',location.pathname);
          // A submit-button click also works before Safari 16's requestSubmit API.
          el('connect').click();
        }
        </script></body></html>
        """
    }
}
