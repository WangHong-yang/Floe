'use strict';
const ice=document.getElementById('ice');
const transcript=document.getElementById('phone-transcript');
const status=document.getElementById('phone-status');
const wave=document.getElementById('phone-wave');
const actions=document.getElementById('session-actions');
const help=document.getElementById('demo-help');
const tapMode=document.getElementById('tap-mode');
const holdMode=document.getElementById('hold-mode');
const original='Let’s make room for the next idea.';
const words=['Let’s',' update',' the',' API',' docs.',' 然后','一起','喝杯','咖啡。'];
let mode='tap',recording=false,busy=false,index=0,pressed=false;
let ticker=null,holdTimer=null,finishTimer=null;
function clearTimers(){clearInterval(ticker);clearTimeout(holdTimer);clearTimeout(finishTimer);ticker=holdTimer=finishTimer=null;}
function showIdle(message){recording=busy=false;ice.classList.remove('active');wave.classList.remove('active');actions.hidden=true;status.textContent=message;ice.setAttribute('aria-label',mode==='tap'?'Tap to start the simulated dictation':'Hold to start the simulated dictation');}
function start(){if(recording||busy)return;clearTimeout(holdTimer);holdTimer=null;recording=true;index=0;transcript.textContent='';ice.classList.add('active');wave.classList.add('active');actions.hidden=false;status.textContent='Listening';ice.setAttribute('aria-label',mode==='tap'?'Tap to finish the simulated dictation':'Release to finish the simulated dictation');append();ticker=setInterval(append,320);}
function append(){if(index<words.length)transcript.textContent+=words[index++];else{clearInterval(ticker);ticker=null;}}
function finish(){clearTimeout(holdTimer);holdTimer=null;if(!recording)return;clearInterval(ticker);ticker=null;recording=false;busy=true;wave.classList.remove('active');ice.classList.remove('active');actions.hidden=true;status.textContent='Finishing';finishTimer=setTimeout(()=>{showIdle('Words inserted. Keep going.');finishTimer=null;},250);}
function cancel(){pressed=false;clearTimers();transcript.textContent=original;showIdle('Ready when you are');}
function setMode(next){cancel();mode=next;tapMode.setAttribute('aria-pressed',String(mode==='tap'));holdMode.setAttribute('aria-pressed',String(mode==='hold'));help.textContent=mode==='tap'?'Tap the ice to start. Tap again to finish.':'Hold the ice for 300 ms. Speak, then release.';showIdle('Ready when you are');}
ice.addEventListener('pointerdown',event=>{if(event.button!==0||pressed||busy)return;pressed=true;ice.setPointerCapture(event.pointerId);if(mode==='hold'){status.textContent='Hold a little longer…';holdTimer=setTimeout(start,300);}});
ice.addEventListener('pointerup',()=>{if(!pressed)return;pressed=false;if(mode==='tap'){if(recording)finish();else start();}else{clearTimeout(holdTimer);holdTimer=null;if(recording)finish();else showIdle('Hold for 300 ms to start');}});
ice.addEventListener('pointercancel',cancel);
ice.addEventListener('lostpointercapture',()=>{if(pressed)cancel();});
ice.addEventListener('keydown',event=>{if(event.code==='Space'||event.code==='Enter'){event.preventDefault();if(event.repeat||pressed||busy)return;pressed=true;if(mode==='hold'){status.textContent='Hold a little longer…';holdTimer=setTimeout(start,300);}}else if(event.code==='Escape')cancel();});
ice.addEventListener('keyup',event=>{if(event.code!=='Space'&&event.code!=='Enter')return;event.preventDefault();if(!pressed)return;pressed=false;if(mode==='tap'){if(recording)finish();else start();}else{clearTimeout(holdTimer);holdTimer=null;if(recording)finish();else showIdle('Hold for 300 ms to start');}});
ice.addEventListener('blur',()=>{if(pressed)cancel();});
document.getElementById('finish').addEventListener('click',finish);
document.getElementById('cancel').addEventListener('click',cancel);
document.getElementById('phone-reset').addEventListener('click',cancel);
tapMode.addEventListener('click',()=>setMode('tap'));
holdMode.addEventListener('click',()=>setMode('hold'));
window.addEventListener('blur',cancel);
document.addEventListener('visibilitychange',()=>{if(document.hidden)cancel();});
