// phoenix_kit_catalogue JS hooks — folded into the host LiveSocket by
// core's :phoenix_kit_js_sources compiler (see PhoenixKit.Module.js_sources/0).
// Registering from a template <script> is the anti-pattern this replaces:
// it works on a hard load but LiveView navigation then logs
// `unknown hook found for "CatalogueTreeDnD"` and drag silently dies —
// hooks must be in the host LiveSocket at construction time.
(function() {
  "use strict";

      window.PhoenixKitCatalogueHooks = window.PhoenixKitCatalogueHooks || {};
      window.PhoenixKitCatalogueHooks.CatalogueTreeDnD = {
        mounted() { this.setupTreeDnD(); },
        updated() { this.setupTreeDnD(); },
        setupTreeDnD() {
          var hook = this;

          // Drag sources: the grip handles only — never the row or the
          // name link (anchors hijack dragstart; <tr> ghosts are broken).
          this.el.querySelectorAll("[data-tree-item]").forEach(function(handle) {
            handle.setAttribute("draggable", "true");
            handle.ondragstart = function(e) {
              var row = handle.closest("[data-tree-uuid]");
              hook._drag = row && {
                uuid: row.dataset.treeUuid,
                type: row.dataset.treeType,
                parent: row.dataset.treeParent
              };
              e.dataTransfer.setData("text/plain", handle.dataset.treeItem);
              e.dataTransfer.effectAllowed = "move";
              if (row) {
                try { e.dataTransfer.setDragImage(row, 12, 12); } catch (err) {}
                row.classList.add("opacity-50");
                hook._dragRowEl = row;
              }
              hook.el.querySelectorAll("[data-tree-rootzone]").forEach(function(z) {
                z.classList.remove("hidden");
              });
            };
            handle.ondragend = function() { hook.endDrag(); };
          });

          // Row targets: file-into (folder middle) or reorder (top/bottom edge).
          this.el.querySelectorAll("[data-tree-uuid]").forEach(function(row) {
            row.ondragover = function(e) {
              var intent = hook.dropIntent(row, e);
              if (!intent) return;
              e.preventDefault();
              // Folder GROUPS nest their children's targets (card view):
              // the innermost target wins and shields its ancestors.
              e.stopPropagation();
              e.dataTransfer.dropEffect = "move";
              hook.showIndicator(row, intent);
            };
            row.ondragleave = function() { hook.clearRow(row); };
            row.ondrop = function(e) {
              var intent = hook.dropIntent(row, e);
              hook.clearRow(row);
              if (!intent || !hook._drag) return;
              e.preventDefault();
              e.stopPropagation();
              var drag = hook._drag;
              if (intent === "into") {
                hook.pushEvent("move_to_folder", { type: drag.type, uuid: drag.uuid, target: row.dataset.treeDrop });
              } else {
                hook.dropAt(drag, row, intent);
              }
            };
          });

          this.el.querySelectorAll("[data-tree-rootzone]").forEach(function(zone) {
            zone.ondragover = function(e) {
              if (!hook._drag) return;
              e.preventDefault();
              e.dataTransfer.dropEffect = "move";
              // Inline + opaque: a bg-primary/10 utility would REPLACE the
              // zone's base background (same CSS property), turning it
              // translucent so the header bleeds through on hover.
              zone.style.backgroundColor =
                "color-mix(in oklab, var(--color-primary) 12%, var(--color-base-100))";
            };
            zone.ondragleave = function() { zone.style.backgroundColor = ""; };
            zone.ondrop = function(e) {
              e.preventDefault();
              zone.style.backgroundColor = "";
              if (hook._drag) {
                hook.pushEvent("move_to_folder", { type: hook._drag.type, uuid: hook._drag.uuid, target: "root" });
              }
            };
          });
        },

        // "into" | "before" | "after" | null for the pointer over `row`.
        // Edges are valid on ANY row: the drop inserts at that row's level
        // (reparenting if needed), not just among original siblings.
        dropIntent(row, e) {
          var drag = this._drag;
          if (!drag || drag.uuid === row.dataset.treeUuid) return null;
          var rect = row.getBoundingClientRect();
          var ratio = (e.clientY - rect.top) / rect.height;
          var isFolder = row.hasAttribute("data-tree-drop");
          // Card-view folder GROUPS are tall containers — shrink the
          // reorder edges to slim strips so most of the box means
          // "into"; table rows keep the 25% edges.
          var edge = rect.height > 80 ? Math.min(12 / rect.height, 0.1) : 0.25;
          if (isFolder && ratio > edge && ratio < 1 - edge) return "into";
          return ratio < 0.5 ? "before" : "after";
        },

        // Insert `drag` before/after `row` WITHIN row's level. The whole
        // level's MERGED order (folders and catalogues interleaved, in DOM
        // order, with the dragged row spliced at the drop point) rides in
        // one event — the server reparents (cycle guard for folders) and
        // writes one position sequence, so where you drop it is where it
        // stays.
        dropAt(drag, row, intent) {
          var targetParent = row.dataset.treeParent;
          var level = [];
          this.el.querySelectorAll("[data-tree-uuid]").forEach(function(r) {
            if (r.dataset.treeParent === targetParent && r.dataset.treeUuid !== drag.uuid) {
              level.push(r);
            }
          });
          var anchorIdx = level.indexOf(row);
          if (anchorIdx < 0) return;
          var insertAt = intent === "before" ? anchorIdx : anchorIdx + 1;

          var order = level.map(function(r) {
            return r.dataset.treeType + ":" + r.dataset.treeUuid;
          });
          order.splice(insertAt, 0, drag.type + ":" + drag.uuid);
          this.pushEvent("drop_row", {
            type: drag.type,
            uuid: drag.uuid,
            parent: targetParent,
            entries: order
          });
        },

        showIndicator(row, intent) {
          this.clearAll();
          if (intent === "into") {
            // Inline style (not a class) so the highlight wins over the
            // table-zebra row background, which otherwise hides it.
            row.style.backgroundColor = "rgba(59, 130, 246, 0.18)";
          } else {
            row.style.boxShadow = intent === "before"
              ? "inset 0 3px 0 0 rgb(59 130 246)"
              : "inset 0 -3px 0 0 rgb(59 130 246)";
          }
        },

        clearRow(row) {
          row.style.backgroundColor = "";
          row.style.boxShadow = "";
        },

        clearAll() {
          var self = this;
          this.el.querySelectorAll("[data-tree-uuid]").forEach(function(r) { self.clearRow(r); });
        },

        endDrag() {
          if (this._dragRowEl) { this._dragRowEl.classList.remove("opacity-50"); this._dragRowEl = null; }
          this._drag = null;
          this.el.querySelectorAll("[data-tree-rootzone]").forEach(function(z) {
            z.classList.add("hidden");
            z.style.backgroundColor = "";
          });
          this.clearAll();
        }
      };

      // ViewPref — keeps the card/comfy/table choice INSTANT while still
      // remembering it per user.
      //
      // The switch itself is core's TableCardView hook: it toggles CSS on
      // markup that is already in the DOM, so it costs nothing. Routing
      // the click through the server instead (which is what made the
      // choice survive a jump to another page) put a round trip and a
      // full table re-render in front of every click — 150-350ms on a
      // good day, and seconds on a busy dev box (Max, 2026-08-28).
      //
      // So: switch on the client, persist in the background. On mount the
      // server's stored choice seeds localStorage, so a page opened in a
      // browser that has never been here still lands on the right view.
      // Live hook instances, so one shared listener can always find a
      // hook that is still attached to push through. A plain "already
      // bound" boolean loses the listener for good the first time two
      // of these overlap: the second mount skips binding, then the
      // first one's destroyed() unbinds, and nothing saves the view
      // again for the rest of the session. Live navigation overlaps
      // them routinely (the new page mounts before the old unmounts).
      var viewPrefHooks = new Set();
      var viewPrefListener = null;

      window.PhoenixKitCatalogueHooks.ViewPref = {
        mounted() {
          var key = this.el.dataset.storageKey;
          var serverView = this.el.dataset.serverView;

          // Seed from the server ONLY for a browser that has never
          // chosen here. Adopting it on every mount looks like "the
          // server is the source of truth", but the save is
          // fire-and-forget: navigate straight after a click and the
          // next page's assign is still the old value, which would
          // then overwrite the choice the user just made and snap the
          // view back. Whoever is looking at this browser wins.
          try {
            if (serverView && !localStorage.getItem(key)) {
              localStorage.setItem(key, serverView);
              window.dispatchEvent(new CustomEvent("phx:table-view-change", {
                detail: { key: key, mode: serverView }
              }));
            }
          } catch (e) {
            /* storage blocked: the server value still rendered server-side */
          }

          viewPrefHooks.add(this);
          if (viewPrefListener) return;

          viewPrefListener = function(e) {
            if (!e.detail || e.detail.key !== key) return;

            // Fire-and-forget: the view has already changed on screen.
            var live = viewPrefHooks.values().next().value;
            if (live) live.pushEvent("set_view", { mode: e.detail.mode });
          };
          window.addEventListener("phx:table-view-change", viewPrefListener);
        },

        destroyed() {
          viewPrefHooks.delete(this);
          if (viewPrefHooks.size === 0 && viewPrefListener) {
            window.removeEventListener("phx:table-view-change", viewPrefListener);
            viewPrefListener = null;
          }
        }
      };
})();
