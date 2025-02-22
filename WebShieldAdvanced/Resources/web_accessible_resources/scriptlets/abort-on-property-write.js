"use strict";
var main = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // src/scriptlets/abort-on-property-write.js
  var abort_on_property_write_exports = {};
  __export(abort_on_property_write_exports, {
    abortOnPropertyWrite: () => abortOnPropertyWrite,
    abortOnPropertyWriteNames: () => abortOnPropertyWriteNames
  });

  // src/helpers/hit.ts
  var hit = (source) => {
    const ADGUARD_PREFIX = "[AdGuard]";
    if (!source.verbose) {
      return;
    }
    try {
      const trace = console.trace.bind(console);
      let label = `${ADGUARD_PREFIX} `;
      if (source.engine === "corelibs") {
        label += source.ruleText;
      } else {
        if (source.domainName) {
          label += `${source.domainName}`;
        }
        if (source.args) {
          label += `#%#//scriptlet('${source.name}', '${source.args.join("', '")}')`;
        } else {
          label += `#%#//scriptlet('${source.name}')`;
        }
      }
      if (trace) {
        trace(label);
      }
    } catch (e) {
    }
    if (typeof window.__debug === "function") {
      window.__debug(source);
    }
  };

  // src/helpers/object-utils.ts
  var isEmptyObject = (obj) => {
    return Object.keys(obj).length === 0 && !obj.prototype;
  };
  function setPropertyAccess(object, property, descriptor) {
    const currentDescriptor = Object.getOwnPropertyDescriptor(object, property);
    if (currentDescriptor && !currentDescriptor.configurable) {
      return false;
    }
    Object.defineProperty(object, property, descriptor);
    return true;
  }

  // src/helpers/random-id.ts
  function randomId() {
    return Math.random().toString(36).slice(2, 9);
  }

  // src/helpers/create-on-error-handler.ts
  function createOnErrorHandler(rid) {
    const nativeOnError = window.onerror;
    return function onError(error, ...args) {
      if (typeof error === "string" && error.includes(rid)) {
        return true;
      }
      if (nativeOnError instanceof Function) {
        return nativeOnError.apply(window, [error, ...args]);
      }
      return false;
    };
  }

  // src/helpers/get-property-in-chain.ts
  function getPropertyInChain(base, chain) {
    const pos = chain.indexOf(".");
    if (pos === -1) {
      return { base, prop: chain };
    }
    const prop = chain.slice(0, pos);
    if (base === null) {
      return { base, prop, chain };
    }
    const nextBase = base[prop];
    chain = chain.slice(pos + 1);
    if ((base instanceof Object || typeof base === "object") && isEmptyObject(base)) {
      return { base, prop, chain };
    }
    if (nextBase === null) {
      return { base, prop, chain };
    }
    if (nextBase !== void 0) {
      return getPropertyInChain(nextBase, chain);
    }
    Object.defineProperty(base, prop, { configurable: true });
    return { base, prop, chain };
  }

  // src/scriptlets/abort-on-property-write.js
  function abortOnPropertyWrite(source, property) {
    if (!property) {
      return;
    }
    const rid = randomId();
    const abort = () => {
      hit(source);
      throw new ReferenceError(rid);
    };
    const setChainPropAccess = (owner, property2) => {
      const chainInfo = getPropertyInChain(owner, property2);
      let { base } = chainInfo;
      const { prop, chain } = chainInfo;
      if (chain) {
        const setter = (a) => {
          base = a;
          if (a instanceof Object) {
            setChainPropAccess(a, chain);
          }
        };
        Object.defineProperty(owner, prop, {
          get: () => base,
          set: setter
        });
        return;
      }
      setPropertyAccess(base, prop, { set: abort });
    };
    setChainPropAccess(window, property);
    window.onerror = createOnErrorHandler(rid).bind();
  }
  var abortOnPropertyWriteNames = [
    "abort-on-property-write",
    // aliases are needed for matching the related scriptlet converted into our syntax
    "abort-on-property-write.js",
    "ubo-abort-on-property-write.js",
    "aopw.js",
    "ubo-aopw.js",
    "ubo-abort-on-property-write",
    "ubo-aopw",
    "abp-abort-on-property-write"
  ];
  abortOnPropertyWrite.primaryName = abortOnPropertyWriteNames[0];
  abortOnPropertyWrite.injections = [
    randomId,
    setPropertyAccess,
    getPropertyInChain,
    createOnErrorHandler,
    hit,
    isEmptyObject
  ];
  return __toCommonJS(abort_on_property_write_exports);
})();

;(function(){
  window.adguardScriptlets = window.adguardScriptlets || {};
  var fn = null;

  // Unwrap the export from "main"
  if (typeof main === 'function') {
    fn = main;
  } else if (main && typeof main.default === 'function') {
    fn = main.default;
  } else {
    for (var key in main) {
      if (typeof main[key] === 'function') {
        fn = main[key];
        break;
      }
    }
  }

  if (!fn) {
    console.warn("No callable function found for scriptlet module: abort-on-property-write");
  }

  var aliases = [];
  Object.keys(main).forEach(function(key) {
    if (/Names$/.test(key)) {
      var arr = main[key];
      if (Array.isArray(arr)) {
        aliases = aliases.concat(arr);
      }
    }
  });

  if (aliases.length === 0 && fn && fn.primaryName) {
    aliases.push(fn.primaryName);
  }

  aliases.forEach(function(alias) {
    window.adguardScriptlets[alias] = fn;
  });
})();