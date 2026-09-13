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
        const lang=(navigator.languages||[navigator.language]).map(x=>x.split('-')[0]).find(x=>translations[x])||'en', t=translations[lang];
        document.documentElement.lang=lang;
        const el=id=>document.getElementById(id), audio=el('audio');
        for(const [id,key] of Object.entries({intro:'intro',codeLabel:'code',connect:'connect',listen:'listen',disconnect:'disconnect',note:'note'}))el(id).textContent=t[key];
        let token='', currentTrack='', latest=null, following=false, generation=0, failures=0;
        function requestSignal(ms){const controller=new AbortController();setTimeout(()=>controller.abort(),ms);return controller.signal;}
        const message=text=>{el('status').textContent=text;};
        function stop(){generation++;token='';currentTrack='';latest=null;following=false;audio.pause();audio.removeAttribute('src');audio.load();el('player').hidden=true;el('join').hidden=false;}
        el('disconnect').onclick=()=>{stop();message('');};
        el('join').onsubmit=async event=>{
          event.preventDefault();el('connect').disabled=true;
          try{
            const response=await fetch('/join',{method:'POST',headers:{'Content-Type':'text/plain'},body:el('code').value,cache:'no-store',signal:requestSignal(8000)});
            if(!response.ok){message(response.status===429?t.busy:t.wrong);return;}
            token=(await response.json()).token;el('code').value='';el('join').hidden=true;el('player').hidden=false;failures=0;message(t.ready);poll(++generation);
          }catch{message(t.ended);}finally{el('connect').disabled=false;}
        };
        function align(state){
          if(Number.isFinite(state.position)&&Math.abs(audio.currentTime-state.position)>1.2){try{audio.currentTime=state.position;}catch{}}
        }
        async function play(){
          try{await audio.play();el('listen').hidden=true;message('');}catch{message(t.blocked);el('listen').hidden=false;}
        }
        el('listen').onclick=()=>{
          if(!latest?.track){message(t.wait);return;}
          following=true;align(latest);el('listen').hidden=true;
          // play() is called directly inside the tap event, as required by Safari.
          play();
        };
        audio.addEventListener('loadedmetadata',()=>{if(latest)align(latest);});
        audio.addEventListener('error',()=>{if(token&&currentTrack){message(t.unsupported);el('listen').hidden=false;}});
        async function poll(run){
          if(!token||run!==generation)return;
          try{
            const response=await fetch('/state',{headers:{Authorization:'Bearer '+token},cache:'no-store',signal:requestSignal(5000)});
            if(!response.ok)throw new Error('session');
            const state=await response.json();if(run!==generation)return;
            failures=0;latest=state;el('title').textContent=state.title||t.wait;el('artist').textContent=state.artist;
            if(state.track!==currentTrack){
              audio.pause();currentTrack=state.track||'';
              if(currentTrack){audio.src='/audio/'+encodeURIComponent(currentTrack)+'?token='+encodeURIComponent(token);audio.load();}
              else{audio.removeAttribute('src');audio.load();}
              el('listen').hidden=following;
            }
            if(!state.track){message(state.message||t.wait);}
            else if(following){align(state);if(state.playing){if(audio.paused&&!audio.ended)play();else if(audio.ended){align(state);play();}}else audio.pause();}
            else message(t.ready);
          }catch{
            if(run!==generation)return;
            // Do not leave the receiver playing a buffered file after the host disappears.
            audio.pause();if(++failures>=3){stop();message(t.ended);return;}message(t.ended);
          }
          if(run===generation)setTimeout(()=>poll(run),750);
        }
        </script></body></html>
        """
    }
}
