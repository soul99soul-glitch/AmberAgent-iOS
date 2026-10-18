import Foundation
import Darwin
import CryptoKit
import Combine
import Observation
import OSLog
import WebKit
#if canImport(UIKit)
import UIKit
#endif

enum IOSWebMountBridgeScripts {
    private static let semanticPrelude = """
      var amberInteractiveQuery="a,button,input,textarea,select,[contenteditable='true'],[role='button'],[role='link'],[role='tab'],[role='menuitem'],[role='checkbox'],[role='radio'],[role='combobox'],[role='textbox'],[role='switch'],[role='row'],[role='treeitem'],[role='gridcell'],[role='option'],[tabindex]:not([tabindex='-1'])";
      function amberSafeURL(raw,base){
        try{var u=new URL(raw,(base&&base.location&&base.location.href)||location.href);return u.origin+u.pathname;}
        catch(e){return "";}
      }
      function amberBridge(){
        var bridge=window.__amberWebMountBridgeV1;
        if(!bridge || bridge.document!==document || !bridge.frames){
          var documentId=(Date.now().toString(36)+Math.random().toString(36).slice(2,10));
          bridge={document:document,window:window,documentId:documentId,revision:0,domRevision:0,urlRevision:0,lastURL:String(location.href||""),nextRef:1,nextFrame:1,refs:{},elementRefs:new WeakMap(),frames:[],frameDiagnostics:[]};
          bridge.snapshotId=function(){return bridge.documentId+":"+bridge.revision;};
          bridge.bump=function(){bridge.revision+=1;return bridge.snapshotId();};
          bridge.noteDomMutation=function(){bridge.domRevision+=1;bridge.revision+=1;bridge.pruneRefs();return bridge.domRevision;};
          bridge.flushMutations=function(){
            var changed=false;
            (bridge.frames||[]).forEach(function(frame){
              if(!frame.observer||!frame.observer.takeRecords) return;
              try{if(frame.observer.takeRecords().length) changed=true;}catch(e){}
            });
            if(changed) bridge.noteDomMutation();
            return changed;
          };
          bridge.pruneRefs=function(){
            Object.keys(bridge.refs).forEach(function(key){
              var item=bridge.refs[key];
              if(!item || !item.isConnected || !item.ownerDocument){delete bridge.refs[key];}
            });
          };
          bridge.refFor=function(el){
            if(!el || el.nodeType!==1) return "";
            var existing=bridge.elementRefs.get(el);
            if(existing) return existing;
            bridge.pruneRefs();
            var ref="wm:"+bridge.documentId+":"+(bridge.nextRef++);
            bridge.elementRefs.set(el,ref);bridge.refs[ref]=el;return ref;
          };
          bridge.frameForDocument=function(doc){
            for(var i=0;i<bridge.frames.length;i++) if(bridge.frames[i].document===doc) return bridge.frames[i];
            return null;
          };
          bridge.queryAll=function(selector,maxResults,visibleOnly,frameId){
            var matches=[], limit=maxResults||600;
            if(frameId && !bridge.frames.some(function(frame){return frame.id===frameId;})) return {errorCode:"stale_frame",matches:[]};
            for(var i=0;i<bridge.frames.length && matches.length<limit;i++){
              if(frameId && bridge.frames[i].id!==frameId) continue;
              try{
                var found=bridge.frames[i].document.querySelectorAll(selector);
                for(var j=0;j<found.length && matches.length<limit;j++){
                  if(!visibleOnly || amberVisible(found[j])) matches.push(found[j]);
                }
              }catch(e){return {errorCode:"invalid_selector",matches:[]};}
            }
            return {errorCode:"",matches:matches};
          };
          bridge.resolve=function(raw){
            var target=String(raw||""), frameId="", selector=target;
            if(target.indexOf("wm:")===0){
              if(target.indexOf("wm:"+bridge.documentId+":")!==0) return {errorCode:"stale_ref",element:null};
              var referenced=bridge.refs[target];
              if(!referenced || !referenced.isConnected || !bridge.frameForDocument(referenced.ownerDocument)){
                return {errorCode:"stale_ref",element:null};
              }
              return {errorCode:"",element:referenced};
            }
            if(target.indexOf("frame:")===0){
              var marker=target.indexOf(":css:");
              if(marker<0) return {errorCode:"invalid_selector",element:null};
              frameId=target.slice(6,marker); selector=target.slice(marker+5);
              for(var f=0;f<bridge.frames.length;f++) if(bridge.frames[f].id===frameId){
                try{return {errorCode:"",element:bridge.frames[f].document.querySelector(selector)};}
                catch(e){return {errorCode:"invalid_selector",element:null};}
              }
              return {errorCode:"stale_frame",element:null};
            }
            if(selector.indexOf("css:")===0) selector=selector.slice(4);
            if(!selector) return {errorCode:"missing_target",element:null};
            var result=bridge.queryAll(selector,1);
            return result.errorCode ? {errorCode:result.errorCode,element:null} : {errorCode:"",element:result.matches[0]||null};
          };
          bridge.refreshFrames=function(){
            var previous=bridge.frames||[], next=[], diagnostics=[], changed=false;
            function previousForFrame(frameElement){
              for(var p=0;p<previous.length;p++) if(previous[p].frameElement===frameElement) return previous[p];
              return null;
            }
            function append(doc,win,frameElement,parent,depth){
              if(depth>8 || next.length>=64) return;
              var old=frameElement?previousForFrame(frameElement):previous[0];
              var state={
                id:frameElement?(old?old.id:"f"+(bridge.nextFrame++)):"root",
                document:doc,window:win,frameElement:frameElement,parentId:parent?parent.id:null,depth:depth,
                observer:old&&old.document===doc?old.observer:null,observedDocument:old&&old.document===doc?old.observedDocument:null
              };
              if(!old || old.document!==doc) changed=true;
              next.push(state);
              var children=[];
              try{children=doc.querySelectorAll("iframe,frame");}catch(e){return;}
              for(var i=0;i<children.length;i++){
                var child=children[i], childDoc=null, childWin=null, src=child.getAttribute("src")||"";
                try{
                  childDoc=child.contentDocument;
                  childWin=child.contentWindow;
                  if(!childDoc || !childWin){
                    var crossOrigin=false;
                    try{if(childWin) void childWin.location.href;}catch(e){crossOrigin=true;}
                    diagnostics.push({frame_id:state.id+"/"+i,frame_ref:bridge.refFor(child),accessible:false,error_code:crossOrigin?"cross_origin_frame":"frame_not_ready",url:amberSafeURL(src,doc.defaultView)});
                    continue;
                  }
                  void childDoc.location.href;
                  append(childDoc,childWin,child,state,depth+1);
                }catch(e){
                  diagnostics.push({frame_id:state.id+"/"+i,frame_ref:bridge.refFor(child),accessible:false,error_code:"cross_origin_frame",url:amberSafeURL(src,doc.defaultView)});
                }
              }
            }
            append(document,window,null,null,0);
            previous.forEach(function(old){
              var still=next.some(function(item){return item.document===old.document;});
              if(!still){
                changed=true;
                Object.keys(bridge.refs).forEach(function(key){
                  var item=bridge.refs[key];
                  if(item && item.ownerDocument===old.document) delete bridge.refs[key];
                });
                if(old.observer&&old.observer.disconnect) try{old.observer.disconnect();}catch(e){}
              }
            });
            bridge.frames=next;
            bridge.frameDiagnostics=diagnostics;
            next.forEach(function(state){
              if(state.observedDocument===state.document) return;
              try{
                state.observer=new MutationObserver(function(records){if(records&&records.length) bridge.noteDomMutation();});
                state.observer.observe(state.document,{subtree:true,childList:true,attributes:true,characterData:true});
                state.observedDocument=state.document;
              }catch(e){}
              try{
                state.eventBump=function(){bridge.revision+=1;};
                state.document.addEventListener("input",state.eventBump,true);
                state.document.addEventListener("change",state.eventBump,true);
                state.window.addEventListener("scroll",state.eventBump,true);
              }catch(e){}
            });
            if(changed) bridge.revision+=1;
            bridge.pruneRefs();
          };
          window.__amberWebMountBridgeV1=bridge;
        }
        var currentURL=String(location.href||"");
        if(bridge.lastURL!==currentURL){bridge.lastURL=currentURL;bridge.urlRevision+=1;bridge.revision+=1;}
        bridge.refreshFrames();
        bridge.flushMutations();
        return bridge;
      }
      function amberFrameForDocument(doc){
        var bridge=window.__amberWebMountBridgeV1;
        return bridge&&bridge.frameForDocument?bridge.frameForDocument(doc):null;
      }
      function amberTopRect(el){
        var rect=el.getBoundingClientRect(), left=rect.left, top=rect.top, state=amberFrameForDocument(el.ownerDocument), guard=0;
        while(state&&state.frameElement&&guard++<8){
          var frame=state.frameElement, frameRect=frame.getBoundingClientRect();
          left+=frameRect.left+(frame.clientLeft||0);top+=frameRect.top+(frame.clientTop||0);
          state=amberFrameForDocument(frame.ownerDocument);
        }
        return {left:left,top:top,right:left+rect.width,bottom:top+rect.height,width:rect.width,height:rect.height};
      }
      function amberVisible(el){
        if(!el || !el.isConnected) return false;
        var ownerDocument=el.ownerDocument, ownerWindow=ownerDocument&&ownerDocument.defaultView||window, node=el;
        while(node&&node.nodeType===1){
          var style=ownerWindow.getComputedStyle?ownerWindow.getComputedStyle(node):null;
          if(node.hidden || (style&&(style.display==="none"||style.visibility==="hidden"||Number(style.opacity)===0))) return false;
          node=node.parentElement;
        }
        var rect=el.getBoundingClientRect();
        if(!(rect.width&&rect.height&&rect.bottom>=0&&rect.right>=0&&rect.top<=(ownerWindow.innerHeight||0)&&rect.left<=(ownerWindow.innerWidth||0))) return false;
        var topRect=amberTopRect(el), bridge=window.__amberWebMountBridgeV1;
        if(!(topRect.width&&topRect.height&&topRect.bottom>=0&&topRect.right>=0&&topRect.top<=(bridge.window.innerHeight||0)&&topRect.left<=(bridge.window.innerWidth||0))) return false;
        var state=amberFrameForDocument(ownerDocument);
        while(state&&state.frameElement){
          var frame=state.frameElement, frameRect=amberTopRect(frame);
          if(!frame.isConnected || !amberVisible(frame)) return false;
          if(topRect.right<=frameRect.left||topRect.left>=frameRect.right||topRect.bottom<=frameRect.top||topRect.top>=frameRect.bottom) return false;
          state=amberFrameForDocument(frame.ownerDocument);
        }
        return true;
      }
      function amberRole(el){
        var explicit=el&&el.getAttribute?el.getAttribute("role"):"";
        if(explicit) return explicit;
        var tag=(el&&el.tagName||"").toLowerCase();
        if(tag==="a") return "link"; if(tag==="button") return "button";
        if(tag==="input"){
          var type=(el.getAttribute("type")||"text").toLowerCase();
          if(type==="file"||type==="color"||type==="hidden") return type;
          if(type==="checkbox"||type==="radio"||type==="button"||type==="submit"||type==="reset"||type==="range") return type==="submit"||type==="reset"?"button":type;
          return "textbox";
        }
        if(tag==="textarea" || (el&&el.isContentEditable)) return "textbox";
        if(tag==="select") return "combobox"; return tag;
      }
      function amberName(el){
        if(!el) return "";
        var tag=(el.tagName||"").toLowerCase(), ownerDocument=el.ownerDocument, label=el.getAttribute&&(el.getAttribute("aria-label")||el.getAttribute("alt")||el.getAttribute("title")||el.getAttribute("placeholder"))||"";
        if(!label&&el.getAttribute){
          var labelledBy=String(el.getAttribute("aria-labelledby")||"").trim().split(/\\s+/).filter(Boolean);
          label=labelledBy.map(function(id){var node=ownerDocument.getElementById(id);return node?(node.innerText||node.textContent||""):"";}).join(" ");
        }
        if(!label&&el.labels&&el.labels.length&&amberVisible(el.labels[0])) label=el.labels[0].innerText||"";
        var text=label||((tag==="input"||tag==="textarea"||tag==="select")?"":(el.innerText||""));
        return String(text).replace(/\\s+/g," ").trim().slice(0,240);
      }
      function amberSelectorForElement(el,path){
        var frame=amberFrameForDocument(el&&el.ownerDocument);
        return frame&&frame.id!=="root"?"frame:"+frame.id+":css:"+path:"css:"+path;
      }
      function amberFrameSummary(){
        var bridge=window.__amberWebMountBridgeV1;
        return (bridge.frames||[]).map(function(frame){return {frame_id:frame.id,parent_frame_id:frame.parentId||"",accessible:true,url:amberSafeURL(frame.document.location&&frame.document.location.href,frame.document.defaultView),depth:frame.depth};});
      }
      function amberSensitiveField(el){
        if(!el || !el.getAttribute) return false;
        var type=(el.getAttribute("type")||"").toLowerCase();
        var autocomplete=(el.getAttribute("autocomplete")||"").toLowerCase();
        var identity=(el.id||"")+" "+(el.name||"")+" "+(el.getAttribute("aria-label")||"")+" "+(el.getAttribute("placeholder")||"");
        return type==="password" || type==="hidden" ||
          /current-password|new-password|one-time-code|cc-number|cc-csc|cc-exp|cc-name/.test(autocomplete) ||
          /password|passwd|passcode|token|secret|cookie|authorization|otp|2fa|mfa|totp|one[-_ ]?time|verification.?code|captcha|card.?number|credit.?card|\\bpan\\b|cvv|cvc|security.?code/i.test(identity);
      }
      function amberLocator(el,includeOrdinal){
        if(!el || !el.getAttribute) return null;
        var sensitive=amberSensitiveField(el), tag=(el.tagName||"").toLowerCase();
        var attrs={};
        ["name","placeholder","aria-label","data-testid","id"].forEach(function(key){
          var value=String(el.getAttribute(key)||"").trim();
          if(!value || (key==="id" && (value.length>64 || /[0-9a-f]{8,}|[0-9]{5,}|^:r[0-9a-z]+:$|[-_:][0-9]+$|^(?:react|radix|headlessui|mui|ember)[-_:]/i.test(value)))) return;
          attrs[key]=value.slice(0,120);
        });
        var landmark=el.closest("form,nav,main,dialog,[role='form'],[role='navigation'],[role='main'],[role='dialog']");
        var landmarkInfo=landmark?{role:amberRole(landmark),name:landmark.hasAttribute("aria-label")||landmark.hasAttribute("aria-labelledby")?amberName(landmark).slice(0,120):""}:null;
        var ordinal=0;
        if(includeOrdinal!==false){
          var scope=landmark||el.ownerDocument.body;
          var peers=scope?Array.prototype.filter.call(scope.querySelectorAll(tag),function(item){return amberRole(item)===amberRole(el);}):[];
          ordinal=peers.indexOf(el)+1;
        }
        var label=sensitive?String(el.getAttribute("aria-label")||el.getAttribute("placeholder")||"").trim().slice(0,120):amberName(el);
        var visibleText=sensitive?"":(tag==="input"||tag==="textarea"||tag==="select"?"":String(el.innerText||"").replace(/\\s+/g," ").trim().slice(0,120));
        var row=el.closest("tr,[role='row'],li,[role='listitem']"), rowContext="";
        if(row){
          var isList=row.matches("li,[role='listitem']");
          var cells=row.querySelectorAll(isList?"[role='heading'],h1,h2,h3,h4,h5,h6,strong,span,p":"th,td,[role='rowheader'],[role='gridcell']");
          for(var i=0;i<cells.length;i++){
            if(cells[i].contains(el)||el.contains(cells[i])) continue;
            rowContext=String(cells[i].innerText||"").replace(/\\s+/g," ").trim().slice(0,120);
            if(rowContext) break;
          }
        }
        function urlPattern(raw){
          try{var u=new URL(raw),path=u.pathname||"/";return u.protocol==="http:"||u.protocol==="https:"?u.origin+(/token|oauth|callback|verify|verification|reset|recovery|magic|authorize|authentication|session/i.test(path)?"/redacted":path):u.protocol+path;}
          catch(e){return "";}
        }
        var pageURL="";
        pageURL=urlPattern(location.href);
        var frame=amberFrameForDocument(el.ownerDocument);
        var frameURL=frame&&frame.frameElement?urlPattern(el.ownerDocument.location.href):"";
        return {role:amberRole(el),tag:tag,name:label,text:visibleText,attributes:attrs,landmark:landmarkInfo,row_context:rowContext,ordinal:ordinal,url_pattern:pageURL,frame_document:frameURL};
      }
      function amberLocate(bridge,locator){
        if(!locator || typeof locator!=="object" || Array.isArray(locator) || !locator.role || !locator.url_pattern || !/^[a-z][a-z0-9-]*$/.test(locator.tag||"")) return {errorCode:"locator_not_found",candidates:[]};
        var queried=bridge.queryAll(locator.tag,600,true);
        if(queried.errorCode) return {errorCode:"locator_not_found",candidates:[]};
        var scored=[];
        function withoutTrailingCount(value){return String(value||"").replace(/\\s*(?:\\([0-9][0-9,.]*\\)|\\[[0-9][0-9,.]*\\]|[0-9][0-9,.]*)\\s*$/," ").trim();}
        queried.matches.forEach(function(el){
          var current=amberLocator(el,false);
          if(!current || current.url_pattern!==locator.url_pattern || current.frame_document!==(locator.frame_document||"") || current.role!==locator.role || current.tag!==locator.tag) return;
          if(!!locator.landmark!==!!current.landmark || (locator.landmark && (current.landmark.role!==locator.landmark.role || current.landmark.name!==locator.landmark.name))) return;
          if((locator.row_context||"")!==current.row_context) return;
          var attrs=locator.attributes||{};
          if((attrs.id && current.attributes.id!==attrs.id) || (attrs["data-testid"] && current.attributes["data-testid"]!==attrs["data-testid"])) return;
          var score=25, strong=0;
          if(locator.landmark) score+=15;
          if(locator.name && current.name===locator.name){score+=40;strong++;}
          else if(locator.name && withoutTrailingCount(locator.name) && withoutTrailingCount(locator.name)===withoutTrailingCount(current.name)) score+=10;
          if(locator.text && current.text===locator.text){score+=15;strong++;}
          else if(locator.text && withoutTrailingCount(locator.text) && withoutTrailingCount(locator.text)===withoutTrailingCount(current.text)) score+=5;
          if(locator.row_context){score+=40;strong++;}
          ["name","placeholder","aria-label","data-testid","id"].forEach(function(key){
            if(attrs[key] && current.attributes[key]===attrs[key]){score+=(key==="data-testid"||key==="id")?40:25;strong++;}
            else if(attrs[key] && key!=="id" && key!=="data-testid" && withoutTrailingCount(attrs[key]) && withoutTrailingCount(attrs[key])===withoutTrailingCount(current.attributes[key])) score+=5;
            else if(attrs[key]) score-=20;
          });
          if(locator.name && current.name!==locator.name && withoutTrailingCount(locator.name)!==withoutTrailingCount(current.name)) score-=30;
          if(locator.text && current.text!==locator.text && withoutTrailingCount(locator.text)!==withoutTrailingCount(current.text)) score-=10;
          scored.push({element:el,score:score,high:strong>0&&score>=65,name:current.name,role:current.role,tag:current.tag});
        });
        scored.sort(function(a,b){return b.score-a.score;});
        var high=scored.filter(function(item){return item.high;});
        if(high.length===1) return {element:high[0].element,candidates:[]};
        return {errorCode:high.length?"locator_ambiguous":"locator_not_found",candidates:scored.slice(0,3).map(function(item){return {role:item.role,tag:item.tag,name:item.name,score:item.score};})};
      }
      function amberActionable(el){
        if(!amberVisible(el)) return false;
        var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window, node=el;
        while(node && node.nodeType===1){
          var style=ownerWindow.getComputedStyle?ownerWindow.getComputedStyle(node):null;
          if(node.inert || node.getAttribute("aria-hidden")==="true" || (style&&style.pointerEvents==="none")) return false;
          node=node.parentElement;
        }
        var frame=amberFrameForDocument(el.ownerDocument);
        if(frame&&frame.frameElement&&!amberActionable(frame.frameElement)) return false;
        return !(el.disabled || (el.getAttribute&&el.getAttribute("aria-disabled")==="true"));
      }
      function amberTypeable(el){
        if(!el || amberSensitiveField(el)) return false;
        if(el.tagName==="TEXTAREA" || el.isContentEditable) return true;
        return el.tagName==="INPUT" && /^(text|email|search|tel|url|number|date|datetime-local|month|week|time)$/.test((el.getAttribute("type")||"text").toLowerCase());
      }
      function amberInteractiveTarget(el){
        for(var node=el;node;node=node.parentElement){
          if(node.matches(amberInteractiveQuery) && typeof node.click==="function" && amberActionable(node)) return node;
        }
        return null;
      }
      function amberActionIdentity(el){
        if(!el) return "";
        var form=el.form;
        var parts=[amberRole(el),amberName(el),el.id||"",el.name||"",el.getAttribute&&el.getAttribute("type")||"",el.getAttribute&&el.getAttribute("aria-label")||""];
        if(form) parts.push(form.id||"",form.name||"",form.getAttribute&&form.getAttribute("aria-label")||"",form.getAttribute&&form.getAttribute("action")||"");
        return parts.join(" ").replace(/\\s+/g," ").trim().slice(0,480);
      }
      function amberActionDisposition(el,method,text,coordinate){
        var identity=amberActionIdentity(el);
        var lower=identity.toLowerCase();
        var key=String(text||"").toLowerCase();
        var human=/captcha|two.?factor|2fa|mfa|\\botp\\b|one.?time|verification.?code|passkey|oauth|sign.?in|log.?in|登录|验证码|人机验证/.test(lower);
        if((method==="type"||method==="keys"||method==="select") && amberSensitiveField(el)) human=true;
        if(human) return {kind:"human",reason:"login_or_sensitive_field",label:amberName(el)};
        if(coordinate) return {kind:"approval",reason:"coordinate_tap",label:amberName(el)};
        if(method==="keys" && key==="enter") return {kind:"approval",reason:"enter_may_submit",label:amberName(el)};
        var buttonType=el && el.getAttribute ? (el.getAttribute("type")||"").toLowerCase() : "";
        var submit=el && el.getAttribute && (buttonType==="submit" || (el.tagName==="BUTTON" && el.form && !buttonType));
        var consequential=/\\b(pay|payment|purchase|buy|checkout|place.?order|submit|authorize|approve|confirm|send|publish|delete|remove)\\b|支付|付款|购买|下单|提交|授权|确认|发送|发布|删除/.test(lower);
        if(method==="type" && el && el.form && /submit|checkout|payment|order|支付|下单|提交/.test(lower)) consequential=true;
        if(method==="select" && /payment|billing|checkout|order|支付|账单|订单/.test(lower)) consequential=true;
        if(submit||consequential) return {kind:"approval",reason:"high_consequence_action",label:amberName(el)};
        return {kind:"safe",reason:"",label:amberName(el)};
      }
    """

    static let state = """
    (function(){
      \(semanticPrelude)
      function cleanUrl(raw){try{var u=new URL(raw);return u.origin+u.pathname;}catch(e){return "";}}
      var bridge=amberBridge();
      var body=document.body;
      var actionTarget=bridge.actionTarget;
      var targetRegionChanged=!!(actionTarget&&actionTarget.region&&
        (!actionTarget.region.isConnected||String(actionTarget.region.outerHTML||"").slice(0,8192)!==actionTarget.markup))
        || !!(actionTarget&&actionTarget.target&&String(actionTarget.target.value||"")!==actionTarget.value);
      var focusChanged=!!(actionTarget&&document.activeElement!==actionTarget.focus);
      var newDialog=!!(actionTarget&&document.querySelectorAll('[role="dialog"],dialog[open]').length>actionTarget.dialogs);
      var textLength=0, linksCount=0;
      bridge.frames.forEach(function(frame){
        if(frame.id!=="root"&&!amberVisible(frame.frameElement)) return;
        var frameBody=frame.document.body;
        textLength+=frameBody&&frameBody.innerText?frameBody.innerText.length:0;
        try{linksCount+=frame.document.links?frame.document.links.length:0;}catch(e){}
      });
      return JSON.stringify({
        url: cleanUrl(location.href),
        title: document.title || "",
        ready_state: document.readyState || "unknown",
        document_id: bridge.documentId,
        page_revision: bridge.revision,
        dom_revision: bridge.domRevision,
        url_revision: bridge.urlRevision,
        snapshot_id: bridge.snapshotId(),
        text_length: textLength,
        links_count: linksCount,
        target_region_changed: targetRegionChanged,
        focus_changed: focusChanged,
        new_dialog: newDialog,
        frame_count: bridge.frames.length,
        frames: amberFrameSummary(),
        frame_diagnostics: bridge.frameDiagnostics,
        viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 },
        scroll: { x: window.scrollX || 0, y: window.scrollY || 0 }
      });
    })();
    """

    static func extract(mode: String, maxChars: Int, maxLinks: Int) -> String {
        let mode = jsString(mode)
        let maxChars = max(0, min(maxChars, 80_000))
        let maxLinks = max(0, min(maxLinks, 100))
        return """
        (function(){
          \(semanticPrelude)
          function cleanUrl(raw){try{var u=new URL(raw, location.href);return u.origin+u.pathname;}catch(e){return "";}}
          function cssPath(el){
            if(!el || !el.tagName) return "";
            var path=[];
            while(el && el.nodeType===1 && path.length<5){
              var part=el.tagName.toLowerCase();
              if(el.id){part += "#" + CSS.escape(el.id); path.unshift(part); break;}
              var parent=el.parentElement;
              if(parent){
                var peers=Array.prototype.filter.call(parent.children,function(x){return x.tagName===el.tagName;});
                if(peers.length>1) part += ":nth-of-type(" + (peers.indexOf(el)+1) + ")";
              }
              path.unshift(part); el=parent;
            }
            return path.join(" > ");
          }
          var bridge=amberBridge();
          var mode=\(mode);
          var body=document.body;
          function currentValueMeta(el){
            var tag=(el&&el.tagName||"").toLowerCase();
            if(tag!=="input"&&tag!=="textarea"&&!el.isContentEditable) return {current_value:"",value_length:0,truncated:false,value_redacted:false};
            if(amberSensitiveField(el)) return {current_value:"",value_length:null,truncated:false,value_redacted:true};
            var raw=el.isContentEditable?String(el.textContent||""):String(el.value||"");
            return {current_value:raw.slice(0,120),value_length:raw.length,truncated:raw.length>120,value_redacted:false};
          }
          if(mode==="interactive" || mode==="snapshot"){
            var queriedNodes=bridge.queryAll(amberInteractiveQuery,200,true);
            if(queriedNodes.errorCode) return JSON.stringify({ok:false,error_code:queriedNodes.errorCode,snapshot_id:bridge.snapshotId()});
            var nodes=queriedNodes.matches.sort(function(a,b){return Number(amberTypeable(b))-Number(amberTypeable(a));}).slice(0,100).map(function(el,idx){
                var rect=amberTopRect(el);
              var valueMeta=currentValueMeta(el);
              return {
                ref:bridge.refFor(el),
                selector:amberSelectorForElement(el,cssPath(el)),
                tag:(el.tagName||"").toLowerCase(),
                role:amberRole(el),
                name:amberName(el),
                text:amberName(el),
                href: el.href ? cleanUrl(el.href) : "",
                visible: amberVisible(el),
                actionable: amberActionable(el),
                typeable: amberTypeable(el) && !el.readOnly && amberActionable(el),
                disabled: !!el.disabled,
                checked: typeof el.checked==="boolean" ? el.checked : null,
                focused: el.ownerDocument.activeElement===el,
                current_value:valueMeta.current_value,
                value_length:valueMeta.value_length,
                truncated:valueMeta.truncated,
                value_redacted:valueMeta.value_redacted,
                rect: {
                  x: Math.round(rect.left || 0),
                  y: Math.round(rect.top || 0),
                  width: Math.round(rect.width || 0),
                  height: Math.round(rect.height || 0)
                }
              };
            });
            if(mode==="interactive"){
              return JSON.stringify({ mode: mode, url: cleanUrl(location.href), document_id:bridge.documentId, page_revision:bridge.revision, dom_revision:bridge.domRevision, url_revision:bridge.urlRevision, snapshot_id:bridge.snapshotId(), nodes: nodes, frame_count:bridge.frames.length, frames:amberFrameSummary(), frame_diagnostics:bridge.frameDiagnostics, truncated_fields:queriedNodes.matches.length>100?["nodes"]:[] });
            }
            function nearbyText(el){
              var text="";
              if(el.getAttribute) text = el.getAttribute("alt") || el.getAttribute("title") || el.getAttribute("aria-label") || "";
              if(!text && el.parentElement) text = el.parentElement.innerText || "";
              return String(text || "").replace(/\\s+/g," ").trim().slice(0,240);
            }
            var queriedCandidates=bridge.queryAll("img,iframe,canvas,video,svg,picture,h1,h2,h3,p,blockquote,article,section",120);
            if(queriedCandidates.errorCode) return JSON.stringify({ok:false,error_code:queriedCandidates.errorCode,snapshot_id:bridge.snapshotId()});
            var candidates=queriedCandidates.matches.map(function(el){
              var rect=amberTopRect(el), interactiveTarget=amberInteractiveTarget(el);
              return {
                ref:bridge.refFor(el),
                selector:amberSelectorForElement(el,cssPath(el)),
                tag:(el.tagName||"").toLowerCase(),
                src: el.currentSrc ? cleanUrl(el.currentSrc) : (el.src ? cleanUrl(el.src) : ""),
                href: el.href ? cleanUrl(el.href) : "",
                alt: el.getAttribute ? (el.getAttribute("alt") || "") : "",
                title: el.getAttribute ? (el.getAttribute("title") || "") : "",
                nearby_text: nearbyText(el),
                visible: amberVisible(el),
                single_click_supported: typeof el.click==="function" && amberActionable(el),
                interactive_target_ref: interactiveTarget?bridge.refFor(interactiveTarget):"",
                rect: {
                  x: Math.round(rect.left || 0),
                  y: Math.round(rect.top || 0),
                  width: Math.round(rect.width || 0),
                  height: Math.round(rect.height || 0)
                }
              };
            }).filter(function(item){ return item.visible && (item.rect.width || item.rect.height); });
            var visibleTextRaw=bridge.frames.filter(function(frame){return frame.id==="root"||amberVisible(frame.frameElement);}).map(function(frame){return frame.document.body&&frame.document.body.innerText?frame.document.body.innerText:"";}).join(" ").replace(/\\s+/g," ").trim();
            var visibleText=visibleTextRaw.slice(0,\(maxChars));
            var queriedLinks=bridge.queryAll("a[href]",500);
            var visibleLinks=(queriedLinks.matches||[]).filter(amberVisible);
            var links=visibleLinks.slice(0,\(maxLinks)).map(function(a){
              return { text:(a.innerText||a.getAttribute("aria-label")||"").trim().slice(0,200), href: cleanUrl(a.href) };
            });
            var totalTextLength=0,totalLinksCount=0;
            bridge.frames.forEach(function(frame){
              if(frame.id!=="root"&&!amberVisible(frame.frameElement)) return;
              var frameBody=frame.document.body;
              totalTextLength+=frameBody&&frameBody.innerText?frameBody.innerText.length:0;
              try{totalLinksCount+=frame.document.links?frame.document.links.length:0;}catch(e){}
            });
            var page={
              url:cleanUrl(location.href),
              title:document.title||"",
              ready_state:document.readyState||"unknown",
              document_id:bridge.documentId,
              page_revision:bridge.revision,
              dom_revision:bridge.domRevision,
              url_revision:bridge.urlRevision,
              snapshot_id:bridge.snapshotId(),
              text_length:totalTextLength,
              links_count:totalLinksCount,
              frame_count:bridge.frames.length,
              frames:amberFrameSummary(),
              frame_diagnostics:bridge.frameDiagnostics,
              viewport:{width:window.innerWidth||0,height:window.innerHeight||0},
              scroll:{x:window.scrollX||0,y:window.scrollY||0}
            };
            return JSON.stringify({
              mode: mode,
              url: cleanUrl(location.href),
              document_id: bridge.documentId,
              page_revision: bridge.revision,
              dom_revision: bridge.domRevision,
              url_revision: bridge.urlRevision,
              snapshot_id: bridge.snapshotId(),
              page: page,
              visible_text: visibleText,
              visible_text_length: visibleTextRaw.length,
              visible_text_returned_length: visibleText.length,
              visible_text_truncated: visibleText.length < visibleTextRaw.length,
              links: links,
              links_count: visibleLinks.length,
              links_returned_count: links.length,
              links_truncated: links.length < visibleLinks.length,
              interactive_elements: nodes,
              viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 },
              interactive_nodes: nodes,
              visual_candidates: candidates,
              frame_count:bridge.frames.length,
              frames:amberFrameSummary(),
              frame_diagnostics:bridge.frameDiagnostics,
              redacted: true,
              truncated_fields: (visibleText.length < visibleTextRaw.length ? ["visible_text"] : [])
                .concat(links.length < visibleLinks.length ? ["links"] : [])
                .concat(queriedNodes.matches.length > 100 ? ["interactive_elements"] : [])
            });
          }
          var textRaw=bridge.frames.filter(function(frame){return frame.id==="root"||amberVisible(frame.frameElement);}).map(function(frame){return frame.document.body&&frame.document.body.innerText?frame.document.body.innerText:"";}).join(" ");
          var text=textRaw.slice(0,\(maxChars));
          var queriedReadableLinks=bridge.queryAll("a[href]",500);
          var readableLinks=(queriedReadableLinks.matches||[]).filter(amberVisible);
          var links=readableLinks.slice(0,\(maxLinks)).map(function(a){
            return { text:(a.innerText||a.getAttribute("aria-label")||"").trim().slice(0,200), href: cleanUrl(a.href) };
          });
          return JSON.stringify({ mode:"readable", url: cleanUrl(location.href), title: document.title || "", document_id:bridge.documentId, page_revision:bridge.revision, dom_revision:bridge.domRevision, url_revision:bridge.urlRevision, snapshot_id:bridge.snapshotId(), text: text, text_length:textRaw.length, returned_text_length:text.length, text_truncated:text.length<textRaw.length, links: links, links_count:readableLinks.length, links_returned_count:links.length, links_truncated:links.length<readableLinks.length, frame_count:bridge.frames.length, frames:amberFrameSummary(), frame_diagnostics:bridge.frameDiagnostics, truncated_fields:(text.length<textRaw.length?["text"]:[]).concat(links.length<readableLinks.length?["links"]:[]) });
        })();
        """
    }

    static func get(selector: String?, target: String?, kind: String, attrName: String?, maxChars: Int) -> String {
        let selectorTarget = selector?.nilIfBlank
        let optionTarget = target?.nilIfBlank
        let targetConflict = selectorTarget != nil && optionTarget != nil && selectorTarget != optionTarget
        let targetLiteral = jsString(selectorTarget ?? optionTarget ?? "css:body")
        let kindLiteral = jsString(kind)
        let attrLiteral = jsString(attrName ?? "")
        let maxChars = max(0, min(maxChars, 100_000))
        return """
        (function(){
          \(semanticPrelude)
          function cleanUrl(raw){try{var u=new URL(raw, location.href);return u.origin+u.pathname;}catch(e){return "";}}
          var bridge=amberBridge(), target=\(targetLiteral), kind=\(kindLiteral), attr=\(attrLiteral);
          if(\(targetConflict ? "true" : "false")){ return JSON.stringify({ok:false,error_code:"conflicting_target_arguments",document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()}); }
          var resolved=bridge.resolve(target), el=resolved.element;
          if(resolved.errorCode){ return JSON.stringify({ok:false,error_code:resolved.errorCode,snapshot_id:bridge.snapshotId()}); }
          if(!el){ return JSON.stringify({ok:false,error_code:"target_not_found",snapshot_id:bridge.snapshotId()}); }
          if(!amberVisible(el)){ return JSON.stringify({ok:false,error_code:"target_not_visible",target_ref:bridge.refFor(el),snapshot_id:bridge.snapshotId()}); }
          var sensitive=amberSensitiveField(el) || /csrf|xsrf|auth/i.test((el.id||"")+" "+(el.name||""));
          if(kind==="value" && sensitive){
            return JSON.stringify({ok:false,error_code:"sensitive_value_denied",value_redacted:true,truncated:false,target_ref:bridge.refFor(el),document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()});
          }
          if(kind==="attr" && /password|passwd|token|csrf|xsrf|secret|cookie|authorization|auth/i.test(attr)){
            return JSON.stringify({ok:false,error_code:"sensitive_attribute_denied",value_redacted:true,truncated:false,target_ref:bridge.refFor(el),document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()});
          }
          if(kind==="attr" && attr.toLowerCase()==="value" && (el.tagName==="INPUT" || el.tagName==="TEXTAREA")){
            return JSON.stringify({ok:false,error_code:"sensitive_attribute_denied",value_redacted:true,truncated:false,target_ref:bridge.refFor(el),document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()});
          }
          var value="";
          if(kind==="value"){ value=el.value || ""; }
          else if(kind==="attr"){ value=attr ? (el.getAttribute(attr) || "") : ""; if(attr==="href" || attr==="src") value=amberSafeURL(value,el.ownerDocument.defaultView); }
          else if(kind==="html"){ value=el.outerHTML || ""; }
          else { value=el.innerText || ""; }
          var rawValue=String(value), returnedValue=rawValue.slice(0,\(maxChars));
          return JSON.stringify({ok:true,target_ref:bridge.refFor(el),kind:kind,value:returnedValue,original_length:rawValue.length,returned_length:returnedValue.length,truncated:returnedValue.length<rawValue.length,value_redacted:false,url:cleanUrl(location.href),document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()});
        })();
        """
    }

    /// Builds a restricted interaction script. Stable refs are document-scoped,
    /// and an optional snapshot id rejects stale actions before they run.
    static func interact(method: String, selector: String?, text: String?, options: [String: Any]) -> String {
        func intOption(_ keys: [String]) -> Int? {
            for key in keys {
                if let value = options[key] as? Int { return value }
                if let value = options[key] as? NSNumber { return value.intValue }
                if let value = options[key] as? Double { return Int(value) }
            }
            return nil
        }

        let method = method.lowercased()
        let selectorTarget = selector?.nilIfBlank
        let optionSelector = (options["selector"] as? String)?.nilIfBlank
        let optionTarget = (options["target"] as? String)?.nilIfBlank
        let providedTargets = [selectorTarget, optionSelector, optionTarget].compactMap { $0 }
        let targetConflict = Set(providedTargets).count > 1
        let target = selectorTarget ?? optionTarget ?? optionSelector ?? ""
        let snapshotId = options["snapshot_id"] as? String ?? ""
        let xLiteral = intOption(["x"]).map(String.init) ?? "null"
        let yLiteral = intOption(["y"]).map(String.init) ?? "null"
        let byY = intOption(["dy", "by_y"]) ?? 0
        let clickCount = max(1, min(intOption(["click_count"]) ?? 1, 2))
        let namedPosition = (options["to"] as? String)?.lowercased() ?? ""
        let maxResults = max(1, min(intOption(["max_results"]) ?? 10, 20))
        let allowHighConsequence = options["_amber_allow_high_consequence"] as? Bool ?? false
        let preflightOnly = options["_amber_preflight_only"] as? Bool ?? false
        let preserveActionTarget = options["_amber_preserve_action_target"] as? Bool ?? false
        let locatorProvided = options["locator"] != nil
        let locatorLiteral = (options["locator"] as? [String: Any]).map(IOSWebMountController.json) ?? "null"

        return """
        (function(){
          \(semanticPrelude)
          var bridge=amberBridge();
          var method=\(jsString(method)), target=\(jsString(target)), text=\(jsString(text ?? ""));
          var locator=\(locatorLiteral);
          var locatorProvided=\(locatorProvided ? "true" : "false");
          var expectedSnapshot=\(jsString(snapshotId));
          var clickCount=\(clickCount);
          var allowHighConsequence=\(allowHighConsequence ? "true" : "false");
          var preflightOnly=\(preflightOnly ? "true" : "false");
          var preserveActionTarget=\(preserveActionTarget ? "true" : "false");
          if(!preflightOnly && !preserveActionTarget) bridge.actionTarget=null;
          function base(extra){
            var value={method:method,document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId()};
            Object.keys(extra||{}).forEach(function(key){value[key]=extra[key];});
            return value;
          }
          function fail(code,extra){return JSON.stringify(base(Object.assign({ok:false,error_code:code},extra||{})));}
          function finish(extra){return JSON.stringify(base(Object.assign({ok:true},extra||{})));}
          var targetConflict=\(targetConflict ? "true" : "false");
          function dispositionFailure(el,coordinate){
            var disposition=amberActionDisposition(el,method,text,coordinate);
            if(disposition.kind==="human"){
              return fail("sensitive_field_requires_human",{
                requires_human:true,
                handoff:true,
                handoff_reason:disposition.reason,
                resume_condition:"user_hands_back_control",
                target_ref:bridge.refFor(el),
                target_label:disposition.label||"",
                reason:"Complete login, verification, CAPTCHA, or sensitive payment input in user-controlled WebMount."
              });
            }
            if(disposition.kind==="approval" && !allowHighConsequence){
              return fail("high_consequence_requires_approval",{
                needs_user_action:true,
                consequence:disposition.reason,
                target_ref:bridge.refFor(el),
                target_label:disposition.label||"",
                reason:"This page action may submit, authorize, pay, send, publish, delete, or otherwise change remote state."
              });
            }
            return "";
          }
          function resolveTarget(required){
            if(!target) return required ? {errorCode:"missing_target",element:null} : {errorCode:"",element:null};
            return bridge.resolve(target);
          }
          if(targetConflict) return fail("conflicting_target_arguments",{dispatched:false,verified:false});
          function isDisabled(el){return !!(el && (el.disabled || (el.getAttribute&&el.getAttribute("aria-disabled")==="true")));}
          function topmost(el){
            var ownerDocument=el.ownerDocument, rect=el.getBoundingClientRect(), x=rect.left+rect.width/2, y=rect.top+rect.height/2;
            var hit=ownerDocument.elementFromPoint(x,y);
            if(hit && hit!==el && !el.contains(hit)) return false;
            var state=amberFrameForDocument(ownerDocument), localX=x, localY=y;
            while(state&&state.frameElement){
              var frame=state.frameElement, frameDocument=frame.ownerDocument, frameRect=frame.getBoundingClientRect();
              var parentX=frameRect.left+(frame.clientLeft||0)+localX, parentY=frameRect.top+(frame.clientTop||0)+localY;
              var parentHit=frameDocument.elementFromPoint(parentX,parentY);
              if(parentHit&&parentHit!==frame&&!frame.contains(parentHit)) return false;
              localX=parentX;localY=parentY;state=amberFrameForDocument(frameDocument);
            }
            return true;
          }
          function nativeSetValue(el,value){
            if(el && el.isContentEditable){el.textContent=value;return;}
            var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window;
            var proto=el.tagName==="TEXTAREA"?ownerWindow.HTMLTextAreaElement&&ownerWindow.HTMLTextAreaElement.prototype:ownerWindow.HTMLInputElement&&ownerWindow.HTMLInputElement.prototype;
            var descriptor=proto&&Object.getOwnPropertyDescriptor(proto,"value");
            if(descriptor&&descriptor.set) descriptor.set.call(el,value); else el.value=value;
          }
          function keyEvent(el,type,key){var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,Constructor=ownerWindow.KeyboardEvent||KeyboardEvent;return el.dispatchEvent(new Constructor(type,{key:key,bubbles:true,cancelable:true}));}
          function inputEvent(el,type,data){
            var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,Constructor=ownerWindow.InputEvent||InputEvent;
            try{return el.dispatchEvent(new Constructor("beforeinput",{inputType:type,data:data,bubbles:true,cancelable:true}));}
            catch(e){return true;}
          }
          function insertText(el,value){
            var current=String(el.value||""), start=typeof el.selectionStart==="number"?el.selectionStart:current.length;
            var end=typeof el.selectionEnd==="number"?el.selectionEnd:start;
            var next=current.slice(0,start)+value+current.slice(end);
            nativeSetValue(el,next);
            try{el.setSelectionRange(start+value.length,start+value.length);}catch(e){}
            var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,InputConstructor=ownerWindow.InputEvent||InputEvent,EventConstructor=ownerWindow.Event||Event;
            try{el.dispatchEvent(new InputConstructor("input",{inputType:"insertText",data:value,bubbles:true}));}
            catch(e){el.dispatchEvent(new EventConstructor("input",{bubbles:true}));}
            return next.length;
          }
          function activeElementDeep(){
            var active=document.activeElement, guard=0;
            while(active&&active.tagName&&active.tagName.toLowerCase()==="iframe"&&active.contentDocument&&guard++<8){active=active.contentDocument.activeElement;}
            return active;
          }
          function currentValueMeta(el){
            if(amberSensitiveField(el)) return {current_value:"",truncated:false,value_redacted:true};
            var raw=el&&el.isContentEditable?String(el.textContent||""):String(el&&el.value||"");
            return {current_value:raw.slice(0,120),truncated:raw.length>120,value_redacted:false};
          }
          function markActionTarget(el){
            var parent=el&&el.parentElement;
            var region=el&&(parent&&parent!==el.ownerDocument.body&&parent!==el.ownerDocument.documentElement?parent:el);
            bridge.actionTarget={
              target:el,
              value:el?String(el.value||""):"",
              region:region,
              markup:region?String(region.outerHTML||"").slice(0,8192):"",
              focus:document.activeElement,
              dialogs:document.querySelectorAll('[role="dialog"],dialog[open]').length
            };
          }
          function elementAtViewportPoint(x,y){
            var currentDocument=bridge.document, hit=currentDocument.elementFromPoint(x,y), guard=0;
            while(hit&&hit.tagName&&hit.tagName.toLowerCase()==="iframe"&&hit.contentDocument&&guard++<8){
              var frameRect=hit.getBoundingClientRect();
              currentDocument=hit.contentDocument;
              hit=currentDocument.elementFromPoint(x-frameRect.left-(hit.clientLeft||0),y-frameRect.top-(hit.clientTop||0));
            }
            return hit;
          }
          function scrollElement(el,position,byY){
            var ownerDocument=el&&el.ownerDocument||bridge.document, ownerWindow=ownerDocument.defaultView||window;
            if(el&&el.tagName&&el.tagName.toLowerCase()==="iframe"&&el.contentWindow&&el.contentDocument){
              if(position==="top") el.contentWindow.scrollTo({top:0});
              else if(position==="bottom") el.contentWindow.scrollTo({top:el.contentDocument.documentElement.scrollHeight});
              else el.contentWindow.scrollBy({top:byY||400});
              return {window:el.contentWindow,element:el};
            }
            if(el){
              var style=ownerWindow.getComputedStyle?ownerWindow.getComputedStyle(el):null;
              var scrollable=style&&/(auto|scroll|overlay)/.test(style.overflowY||"")&&el.scrollHeight>el.clientHeight;
              if(scrollable){
                if(position==="top") el.scrollTop=0;
                else if(position==="bottom") el.scrollTop=el.scrollHeight;
                else if(el.scrollBy) el.scrollBy({top:byY||400});
                else el.scrollTop+=byY||400;
              }else{
                el.scrollIntoView({block:position==="top"?"start":position==="bottom"?"end":"center",inline:"nearest"});
                var frameState=amberFrameForDocument(ownerDocument);
                while(frameState&&frameState.frameElement){
                  frameState.frameElement.scrollIntoView({block:position==="top"?"start":position==="bottom"?"end":"center",inline:"nearest"});
                  frameState=amberFrameForDocument(frameState.frameElement.ownerDocument);
                }
              }
              return {window:ownerWindow,element:el};
            }
            if(position==="top") ownerWindow.scrollTo({top:0});
            else if(position==="bottom") ownerWindow.scrollTo({top:ownerDocument.documentElement.scrollHeight});
            else ownerWindow.scrollBy({top:byY||400});
            return {window:ownerWindow,element:null};
          }
          if(expectedSnapshot && expectedSnapshot!==bridge.snapshotId()){
            return fail("stale_snapshot",{expected_snapshot_id:expectedSnapshot});
          }

          if(method==="click" || method==="tap"){
            var el=null, x=\(xLiteral), y=\(yLiteral);
            if(method==="tap" && x!==null && y!==null){el=elementAtViewportPoint(x,y);}
            else {
              var resolved=resolveTarget(true);
              if(resolved.errorCode) return fail(resolved.errorCode);
              el=resolved.element;
            }
            if(!el) return fail("target_not_found");
            if(clickCount===1 && typeof el.click!=="function") return fail("target_not_clickable",{
              target_ref:bridge.refFor(el),
              interactive_target_ref:bridge.refFor(amberInteractiveTarget(el)),
              reason:"This visual target does not support a direct single click. Choose an interactive element or use wm_find to locate the control."
            });
            if(!preflightOnly && method==="click") scrollElement(el,"center",0);
            if(!amberVisible(el)) return fail("target_not_visible",{target_ref:bridge.refFor(el)});
            if(!amberActionable(el)) return fail("target_not_actionable",{target_ref:bridge.refFor(el)});
            if(isDisabled(el)) return fail("target_disabled",{target_ref:bridge.refFor(el)});
            if(method==="click" && !topmost(el)) return fail("target_occluded",{target_ref:bridge.refFor(el)});
            var blocked=dispositionFailure(el,method==="tap" && x!==null && y!==null);
            if(blocked) return blocked;
            if(preflightOnly) return finish({preflight_only:true,target_ref:bridge.refFor(el),target_label:amberName(el),verified:true});
            var actionLocator=target.indexOf("wm:")===0?amberLocator(el):null;
            markActionTarget(el);
            if(typeof el.focus==="function" && (amberTypeable(el) || el.tabIndex>=0)){
              // WebMount WKWebViews often run detached from any window; there WebKit
              // moves activeElement but may skip the focus/focusin events, so
              // focus-revealed content never appears. Replay them only when this
              // call newly focused the element and no native focus event fired.
              var focusDoc=el.ownerDocument,wasFocused=focusDoc.activeElement===el,sawFocus=false;
              var noteFocus=function(){sawFocus=true;};
              el.addEventListener("focus",noteFocus,true);
              el.focus();
              el.removeEventListener("focus",noteFocus,true);
              if(!wasFocused && !sawFocus && focusDoc.activeElement===el){
                try{
                  var focusWindow=focusDoc.defaultView||window,FocusCtor=focusWindow.FocusEvent||FocusEvent;
                  el.dispatchEvent(new FocusCtor("focus",{bubbles:false,cancelable:false,view:focusWindow}));
                  el.dispatchEvent(new FocusCtor("focusin",{bubbles:true,cancelable:false,view:focusWindow}));
                }catch(e){}
              }
            }
            var doubleClickEvent=null;
            if(clickCount===2){
              try{
                var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,MouseConstructor=ownerWindow.MouseEvent||MouseEvent;
                doubleClickEvent=new MouseConstructor("dblclick",{bubbles:true,cancelable:true,detail:2,view:ownerWindow});
              }catch(e){return fail("double_click_dispatch_failed",{target_ref:bridge.refFor(el)});}
              el.dispatchEvent(new MouseConstructor("click",{bubbles:true,cancelable:true,detail:1,view:ownerWindow}));
              el.dispatchEvent(new MouseConstructor("click",{bubbles:true,cancelable:true,detail:2,view:ownerWindow}));
              el.dispatchEvent(doubleClickEvent);
            }else el.click();
            bridge.bump();
            return finish({found:true,target_ref:bridge.refFor(el),target_label:amberName(el),locator:actionLocator,dispatched:true,click_count:clickCount,dblclick_dispatched:clickCount===2,focused:el.ownerDocument.activeElement===el,verified:false});
          }

          if(method==="type" || method==="keys"){
            var hasExplicitTarget=!!target, resolved=resolveTarget(method==="type"), el=resolved.element;
            if(resolved.errorCode) return fail(resolved.errorCode);
            if(!el && method==="keys" && !hasExplicitTarget) el=activeElementDeep();
            if(!el) return fail(hasExplicitTarget?"target_not_found":"focused_field_not_found");
            if(el===el.ownerDocument.body || el===el.ownerDocument.documentElement) return fail("focused_field_not_found");
            if(amberSensitiveField(el)) return fail("sensitive_field_requires_human",{requires_human:true,handoff:true,resume_condition:"user_hands_back_control",target_ref:bridge.refFor(el)});
            var contentEditable=!!el.isContentEditable;
            if(!(el.tagName==="INPUT" || el.tagName==="TEXTAREA" || (method==="type" && contentEditable))) return fail("target_not_typeable",{target_ref:bridge.refFor(el)});
            if(el.tagName==="INPUT"){
              var inputType=String(el.getAttribute("type")||"text").toLowerCase();
              var typeable={text:true,email:true,search:true,tel:true,url:true,number:true,date:true,"datetime-local":true,month:true,week:true,time:true};
              if(!typeable[inputType]) return fail("target_not_typeable",{target_ref:bridge.refFor(el),input_type:inputType});
            }
            if(!amberVisible(el)) return fail("target_not_visible",{target_ref:bridge.refFor(el)});
            if(!amberActionable(el)) return fail("target_not_actionable",{target_ref:bridge.refFor(el)});
            var blocked=dispositionFailure(el,false);
            if(blocked) return blocked;
            if(isDisabled(el) || el.readOnly) return fail("target_not_editable",{target_ref:bridge.refFor(el)});
            if(preflightOnly) return finish({preflight_only:true,target_ref:bridge.refFor(el),target_label:amberName(el),verified:true});
            var actionLocator=method==="type"&&target.indexOf("wm:")===0?amberLocator(el):null;
            markActionTarget(el);
            var wasFocused=el.ownerDocument.activeElement===el;
            el.focus();
            if(method==="keys" && !wasFocused && typeof el.setSelectionRange==="function"){
              var end=String(el.value||"").length;
              try{el.setSelectionRange(end,end);}catch(e){}
            }
            if(method==="type"){
              if(!inputEvent(el,"insertText",text)) return fail("input_cancelled",{target_ref:bridge.refFor(el)});
              nativeSetValue(el,text);
              var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,InputConstructor=ownerWindow.InputEvent||InputEvent,EventConstructor=ownerWindow.Event||Event;
              try{el.dispatchEvent(new InputConstructor("input",{inputType:"insertText",data:text,bubbles:true}));}
              catch(e){el.dispatchEvent(new EventConstructor("input",{bubbles:true}));}
              bridge.bump();
              var resolvedValue=contentEditable?String(el.textContent||""):String(el.value||"");
              var typeVerified=resolvedValue===text;
              var valueMeta=currentValueMeta(el);
              return finish({found:true,target_ref:bridge.refFor(el),target_label:amberName(el),locator:actionLocator,value_length:resolvedValue.length,current_value:valueMeta.current_value,truncated:valueMeta.truncated,value_redacted:valueMeta.value_redacted,focused:el.ownerDocument.activeElement===el,verified:typeVerified});
            }
            var special={enter:"Enter",tab:"Tab",escape:"Escape",backspace:"Backspace",arrowup:"ArrowUp",arrowdown:"ArrowDown",arrowleft:"ArrowLeft",arrowright:"ArrowRight"};
            var key=special[text.toLowerCase()]||"", defaultApplied=false;
            if(key){
              var allowed=keyEvent(el,"keydown",key);
              if(allowed && key==="Backspace"){
                var current=String(el.value||""), start=typeof el.selectionStart==="number"?el.selectionStart:current.length, end=typeof el.selectionEnd==="number"?el.selectionEnd:start;
                if(start===end && start>0) start-=1;
                nativeSetValue(el,current.slice(0,start)+current.slice(end));
                try{el.setSelectionRange(start,start);}catch(e){}
                var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,EventConstructor=ownerWindow.Event||Event;
                el.dispatchEvent(new EventConstructor("input",{bubbles:true})); defaultApplied=true;
              }
              keyEvent(el,"keyup",key); bridge.bump();
              var specialValue=String(el.value||""), specialMeta=currentValueMeta(el);
              return finish({found:true,target_ref:bridge.refFor(el),target_label:amberName(el),key:key,event_dispatched:true,default_applied:defaultApplied,trusted:false,value_length:specialValue.length,current_value:specialMeta.current_value,truncated:specialMeta.truncated,value_redacted:specialMeta.value_redacted,verified:defaultApplied});
            }
            var beforeLength=String(el.value||"").length, inserted=0;
            for(var i=0;i<text.length;i++){
              var ch=text.charAt(i), allowed=keyEvent(el,"keydown",ch);
              if(allowed && inputEvent(el,"insertText",ch)){insertText(el,ch);inserted+=1;}
              keyEvent(el,"keyup",ch);
            }
            bridge.bump();
            var afterLength=String(el.value||"").length;
            var typedMeta=currentValueMeta(el);
            return finish({found:true,target_ref:bridge.refFor(el),target_label:amberName(el),locator:actionLocator,event_count:text.length,inserted_count:inserted,trusted:false,value_length:afterLength,current_value:typedMeta.current_value,truncated:typedMeta.truncated,value_redacted:typedMeta.value_redacted,verified:inserted===text.length&&afterLength>=beforeLength});
          }

          if(method==="scroll"){
            var resolved=resolveTarget(false), el=resolved.element;
            if(resolved.errorCode) return fail(resolved.errorCode);
            if(el && /^(IFRAME|FRAME)$/.test(el.tagName) && !bridge.frames.some(function(frame){return frame.frameElement===el;})){
              var frameDiagnostic=bridge.frameDiagnostics.find(function(item){return item.frame_ref===bridge.refFor(el);});
              return fail(frameDiagnostic?frameDiagnostic.error_code:"frame_not_ready",{target_ref:bridge.refFor(el)});
            }
            if(preflightOnly) return finish({preflight_only:true,target_ref:el?bridge.refFor(el):"",target_label:el?amberName(el):"",verified:true});
            markActionTarget(el);
            var position=\(jsString(namedPosition)), byY=\(byY);
            var beforeWindow=el&&el.tagName&&el.tagName.toLowerCase()==="iframe"&&el.contentWindow?el.contentWindow:el&&el.ownerDocument&&el.ownerDocument.defaultView||window;
            var beforeX=Math.round(beforeWindow.scrollX||0), beforeY=Math.round(beforeWindow.scrollY||0), beforeElementScrollTop=el&&typeof el.scrollTop==="number"?el.scrollTop:null, beforeTopRect=el?amberTopRect(el):null, scrollResult=scrollElement(el,position,byY);
            bridge.bump();
            var afterWindow=scrollResult.window||beforeWindow, afterX=Math.round(afterWindow.scrollX||0), afterY=Math.round(afterWindow.scrollY||0), elementScrollTop=scrollResult.element&&scrollResult.element.scrollTop, afterTopRect=el?amberTopRect(el):null, topRectChanged=beforeTopRect&&afterTopRect&&(beforeTopRect.left!==afterTopRect.left||beforeTopRect.top!==afterTopRect.top);
            return finish({found:!!el,target_ref:el?bridge.refFor(el):"",target_label:el?amberName(el):"",scroll_x:afterX,scroll_y:afterY,element_scroll_top:typeof elementScrollTop==="number"?Math.round(elementScrollTop):null,verified:beforeX!==afterX||beforeY!==afterY||(typeof elementScrollTop==="number"&&elementScrollTop!==beforeElementScrollTop)||!!topRectChanged});
          }

          if(method==="select"){
            var resolved=resolveTarget(true), el=resolved.element;
            if(resolved.errorCode) return fail(resolved.errorCode);
            if(!el) return fail("target_not_found");
            if(el.tagName!=="SELECT") return fail("target_not_selectable",{target_ref:bridge.refFor(el)});
            if(!amberVisible(el)) return fail("target_not_visible",{target_ref:bridge.refFor(el)});
            if(!amberActionable(el)) return fail("target_not_actionable",{target_ref:bridge.refFor(el)});
            var blocked=dispositionFailure(el,false);
            if(blocked) return blocked;
            if(preflightOnly) return finish({preflight_only:true,target_ref:bridge.refFor(el),target_label:amberName(el),verified:true});
            var option=Array.prototype.find.call(el.options,function(item){return item.value===text;});
            if(!option) return fail("option_not_found",{target_ref:bridge.refFor(el)});
            var actionLocator=target.indexOf("wm:")===0?amberLocator(el):null;
            markActionTarget(el);
            var ownerWindow=el.ownerDocument&&el.ownerDocument.defaultView||window,EventConstructor=ownerWindow.Event||Event;
            el.value=text; el.dispatchEvent(new EventConstructor("input",{bubbles:true})); el.dispatchEvent(new EventConstructor("change",{bubbles:true})); bridge.bump();
            return finish({found:true,target_ref:bridge.refFor(el),target_label:amberName(el),locator:actionLocator,selected_index:el.selectedIndex,verified:el.value===text});
          }

          if(method==="find"){
            var matches=[], maxResults=\(maxResults), query=text.toLowerCase();
            if(locatorProvided && !locator) return fail("locator_not_found",{candidates:[]});
            if(locator){
              if(target || text) return fail("conflicting_target_arguments");
              var located=amberLocate(bridge,locator);
              if(located.errorCode) return fail(located.errorCode,{candidates:located.candidates});
              matches=[located.element];
            } else if(target){
              if(target.indexOf("wm:")===0){
                var resolved=bridge.resolve(target);
                if(resolved.errorCode) return fail(resolved.errorCode);
                if(resolved.element) matches=[resolved.element];
              } else {
                var css=target.indexOf("css:")===0?target.slice(4):target, frameId="";
                if(target.indexOf("frame:")===0){
                  var marker=target.indexOf(":css:");
                  if(marker<0) return fail("invalid_selector");
                  frameId=target.slice(6,marker);css=target.slice(marker+5);
                }
                var queried=bridge.queryAll(css,maxResults,true,frameId);
                if(queried.errorCode) return fail(queried.errorCode);
                matches=queried.matches;
              }
            } else if(query){
              var queried=bridge.queryAll(amberInteractiveQuery+",label,p,span,div,main,li,h1,h2,h3,h4,h5,h6,td,th,article,section,[role]",600,true);
              if(queried.errorCode) return fail(queried.errorCode);
              matches=queried.matches.map(function(item){return {element:item,name:amberName(item).toLowerCase(),interactive:item.matches(amberInteractiveQuery)};})
                .filter(function(item){return item.name.indexOf(query)>=0;})
                .sort(function(a,b){return Number(b.name===query)-Number(a.name===query) || Number(b.interactive)-Number(a.interactive);})
                .slice(0,maxResults).map(function(item){return item.element;});
            }
            var output=matches.filter(amberVisible).slice(0,maxResults).map(function(item){return {ref:bridge.refFor(item),tag:(item.tagName||"").toLowerCase(),role:amberRole(item),name:amberName(item),visible:true,actionable:amberActionable(item),typeable:amberTypeable(item)&&!item.readOnly&&amberActionable(item),focused:item.ownerDocument.activeElement===item};});
            return finish({found:output.length>0,count:output.length,matches:output,verified:output.length>0});
          }
          return fail("unsupported_interaction");
        })();
        """
    }

    static func waitProbe(condition: String, options: [String: Any]) -> String {
        let selector = (options["selector"] as? String)?.nilIfBlank ?? ""
        let text = options["text"] as? String ?? ""
        let urlFragment = options["url_contains"] as? String ?? ""
        let readyState = (options["ready_state"] as? String)?.lowercased() ?? "complete"
        let beforeDocumentId = (options["before_document_id"] as? String)?.nilIfBlank ?? ""
        let beforeURL = (options["before_url"] as? String)?.nilIfBlank ?? ""
        let beforeURLRevision = (options["before_url_revision"] as? Int)
            ?? (options["before_url_revision"] as? NSNumber)?.intValue
            ?? (options["before_url_revision"] as? Double).map(Int.init)
        let beforeDOMRevision = (options["before_dom_revision"] as? Int)
            ?? (options["before_dom_revision"] as? NSNumber)?.intValue
            ?? (options["before_dom_revision"] as? Double).map(Int.init)
        let requirePageChange = options["require_page_change"] as? Bool ?? false
        let beforeURLRevisionLiteral = beforeURLRevision.map(String.init) ?? "null"
        let beforeDOMRevisionLiteral = beforeDOMRevision.map(String.init) ?? "null"
        return """
        (function(){
          \(semanticPrelude)
          function cleanUrl(raw){try{var u=new URL(raw);return u.origin+u.pathname;}catch(e){return "";}}
          var bridge=amberBridge(), condition=\(jsString(condition)), conditionMatched=false, matched=false, errorCode="";
          var beforeDocumentId=\(jsString(beforeDocumentId)), beforeURL=\(jsString(beforeURL)), beforeURLRevision=\(beforeURLRevisionLiteral), beforeDOMRevision=\(beforeDOMRevisionLiteral), requirePageChange=\(requirePageChange ? "true" : "false");
          var currentURL=cleanUrl(location.href), sameDocument=!!beforeDocumentId && bridge.documentId===beforeDocumentId, urlRevisionChanged=sameDocument && beforeURLRevision!==null && bridge.urlRevision!==beforeURLRevision, documentChanged=!!beforeDocumentId && !sameDocument, urlChanged=urlRevisionChanged || (!!beforeURL && currentURL!==cleanUrl(beforeURL)), domChanged=beforeDOMRevision!==null && bridge.domRevision!==beforeDOMRevision, pageChanged=documentChanged||urlChanged||domChanged;
          if(condition==="selector"){
            var resolved=bridge.resolve(\(jsString(selector)));
            errorCode=resolved.errorCode||""; conditionMatched=!!resolved.element && amberVisible(resolved.element);
          } else if(condition==="text"){
            conditionMatched=bridge.frames.some(function(frame){return (frame.id==="root"||amberVisible(frame.frameElement)) && String(frame.document.body&&frame.document.body.innerText||"").indexOf(\(jsString(text)))>=0;});
          } else if(condition==="url_contains"){
            conditionMatched=String(location.href||"").indexOf(\(jsString(urlFragment)))>=0;
          } else if(condition==="ready_state"){
            var expected=\(jsString(readyState));
            conditionMatched=expected==="interactive"?(document.readyState==="interactive"||document.readyState==="complete"):document.readyState===expected;
          } else if(condition==="document_changed"){
            conditionMatched=documentChanged;
          } else if(condition==="url_changed"){
            conditionMatched=urlChanged;
          } else if(condition==="dom_stable"){
            conditionMatched=true;
          }
          matched=conditionMatched && (!requirePageChange || pageChanged);
          return JSON.stringify({ok:!errorCode,matched:matched,condition_matched:conditionMatched,error_code:errorCode,ready_state:document.readyState||"unknown",url:currentURL,document_id:bridge.documentId,page_revision:bridge.revision,dom_revision:bridge.domRevision,url_revision:bridge.urlRevision,snapshot_id:bridge.snapshotId(),document_changed:documentChanged,url_changed:urlChanged,dom_changed:domChanged,page_changed:pageChanged,require_page_change:requirePageChange,before_document_id:beforeDocumentId,before_url:beforeURL?cleanUrl(beforeURL):"",before_url_revision:beforeURLRevision,before_dom_revision:beforeDOMRevision});
        })();
        """
    }

    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2 else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}

