'use strict';
const button=document.getElementById('hold');
const label=document.getElementById('hold-label');
const transcript=document.getElementById('transcript');
const wave=document.getElementById('wave');
const words=['Let’s',' make',' room',' for',' the',' next',' idea.',' 用',' Floe，','把','想法','说','出来。'];
let timer=null,index=0;
function stop(){clearInterval(timer);timer=null;button.classList.remove('active');wave.classList.remove('active');label.textContent='Hold to speak';}
function reset(){stop();index=0;transcript.textContent='Let’s make room for the next idea.';}
function start(){if(timer)return;if(index===words.length)index=0;if(index===0)transcript.textContent='';button.classList.add('active');wave.classList.add('active');label.textContent='Listening';transcript.textContent+=words[index++];timer=setInterval(()=>{if(index<words.length)transcript.textContent+=words[index++];else stop();},280);}
button.addEventListener('pointerdown',e=>{if(e.button!==0)return;button.setPointerCapture(e.pointerId);start();});
button.addEventListener('pointerup',stop);
button.addEventListener('pointercancel',stop);
button.addEventListener('lostpointercapture',stop);
button.addEventListener('keydown',e=>{if(e.code==='Space'||e.code==='Enter'){e.preventDefault();if(!e.repeat)start();}});
button.addEventListener('keyup',e=>{if(e.code==='Space'||e.code==='Enter'){e.preventDefault();stop();}});
button.addEventListener('blur',stop);
window.addEventListener('blur',stop);
document.addEventListener('visibilitychange',()=>{if(document.hidden)stop();});
document.getElementById('reset').addEventListener('click',reset);
