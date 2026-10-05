(function(){
  if(matchMedia('(prefers-reduced-motion: reduce)').matches)return;
  var d=document,p=d.createElement('div');
  p.className='fx-progress';d.body.appendChild(p);
  function sc(){var h=d.documentElement,m=h.scrollHeight-h.clientHeight;p.style.transform='scaleX('+(m>0?h.scrollTop/m:0)+')';}
  addEventListener('scroll',sc,{passive:true});
  d.addEventListener('click',function(e){
    var b=e.target.closest&&e.target.closest('button.btn,.page-btn');if(!b)return;
    var r=b.getBoundingClientRect(),s=Math.max(r.width,r.height),i=d.createElement('span');
    i.className='fx-rip';i.style.cssText='width:'+s+'px;height:'+s+'px;left:'+(e.clientX-r.left-s/2)+'px;top:'+(e.clientY-r.top-s/2)+'px';
    b.appendChild(i);setTimeout(function(){i.remove();},650);
  });
})();
