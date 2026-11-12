(globalThis.TURBOPACK||(globalThis.TURBOPACK=[])).push(["object"==typeof document?document.currentScript:void 0,707510,e=>{"use strict";var t=e.i(171206),i=e.i(419882),r=(0,t.__name)((e,t)=>{let r;return"sandbox"===t&&(r=(0,i.select)("#i"+e)),("sandbox"===t?(0,i.select)(r.nodes()[0].contentDocument.body):(0,i.select)("body")).select(`[id="${e}"]`)},"getDiagramElement");e.s(["getDiagramElement",0,r])},572247,e=>{"use strict";var t=(0,e.i(171206).__name)(()=>`
  /* Font Awesome icon styling - consolidated */
  .label-icon {
    display: inline-block;
    height: 1em;
    overflow: visible;
    vertical-align: -0.125em;
  }
  
  .node .label-icon path {
    fill: currentColor;
    stroke: revert;
    stroke-width: revert;
  }
`,"getIconStyles");e.s(["getIconStyles",0,t])},35815,e=>{"use strict";var t=e.i(80926),i=e.i(171206),r=(0,i.__name)((e,r,l,o)=>{e.attr("class",l);let{width:n,height:c,x:d,y:g}=s(e,r);(0,t.configureSvgSize)(e,c,n,o);let u=a(d,g,n,c,r);e.attr("viewBox",u),i.log.debug(`viewBox configured: ${u} with padding: ${r}`)},"setupViewPortForSVG"),s=(0,i.__name)((e,t)=>{let i=e.node()?.getBBox()||{width:0,height:0,x:0,y:0};return{width:i.width+2*t,height:i.height+2*t,x:i.x,y:i.y}},"calculateDimensionsWithPadding"),a=(0,i.__name)((e,t,i,r,s)=>`${e-s} ${t-s} ${i} ${r}`,"createViewBox");e.s(["setupViewPortForSVG",0,r])},676395,e=>{"use strict";var t=e.i(977662);e.i(572247),e.i(707510),e.i(35815),e.i(893016),e.i(754802),e.i(620502),e.i(407983),e.i(102256),e.i(833448),e.i(780262),e.i(195923),e.i(80926);var i=e.i(171206),r={parser:t.classDiagram_default,get db(){return new t.ClassDB},renderer:t.classRenderer_v3_unified_default,styles:t.styles_default,init:(0,i.__name)(e=>{e.class||(e.class={}),e.class.arrowMarkerAbsolute=e.arrowMarkerAbsolute},"init")};e.s(["diagram",0,r])}]);