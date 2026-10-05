(function(){
  if(matchMedia('(prefers-reduced-motion: reduce)').matches)return;
  var d=document,o=d.createElement('div'),p=d.createElement('div');
  o.className='fx-orb';p.className='fx-progress';d.body.appendChild(o);d.body.appendChild(p);
  var tx=innerWidth/2,ty=200,x=tx,y=ty;
  addEventListener('pointermove',function(e){
    tx=e.clientX;ty=e.clientY;
    var t=e.target.closest&&e.target.closest('.glass,.panel,.time-slot');
    if(t){var r=t.getBoundingClientRect();t.style.setProperty('--mx',(e.clientX-r.left)+'px');t.style.setProperty('--my',(e.clientY-r.top)+'px');}
  },{passive:true});
  (function loop(){x+=(tx-x)*.12;y+=(ty-y)*.12;o.style.transform='translate3d('+(x-200)+'px,'+(y-200)+'px,0)';requestAnimationFrame(loop);})();
  function sc(){var h=d.documentElement,m=h.scrollHeight-h.clientHeight;p.style.transform='scaleX('+(m>0?h.scrollTop/m:0)+')';}
  addEventListener('scroll',sc,{passive:true});
  d.addEventListener('click',function(e){
    var b=e.target.closest&&e.target.closest('button.btn,.page-btn');if(!b)return;
    var r=b.getBoundingClientRect(),s=Math.max(r.width,r.height),i=d.createElement('span');
    i.className='fx-rip';i.style.cssText='width:'+s+'px;height:'+s+'px;left:'+(e.clientX-r.left-s/2)+'px;top:'+(e.clientY-r.top-s/2)+'px';
    b.appendChild(i);setTimeout(function(){i.remove();},650);
  });
})();
