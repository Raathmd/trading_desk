defmodule TradingDesk.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
      <title>Trading Desk</title>
      <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
      <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/phoenix@1.7.21/priv/static/phoenix.min.js"></script>
      <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@0.20.17/priv/static/phoenix_live_view.min.js"></script>
      <script>
        // Apply saved theme immediately to avoid flash (documentElement available in <head>)
        (function() {
          if (localStorage.getItem('td-theme') === 'light') document.documentElement.classList.add('theme-light');
        })();
        document.addEventListener("DOMContentLoaded", function() {
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

          let Hooks = {}
          Hooks.Slider = {
            mounted() {
              this.el.addEventListener("input", (e) => {
                this.pushEvent("update_var", {key: this.el.dataset.key, value: e.target.value})
              })
            },
            updated() {
              // Don't let server override slider while user is dragging
            }
          }

          Hooks.VesselMap = {
            mounted() {
              if (typeof L === 'undefined') return;
              const data = JSON.parse(this.el.dataset.mapdata || '{}');
              const map = L.map(this.el, {
                center: data.center || [20, 0],
                zoom: data.zoom || 2,
                zoomControl: true,
                attributionControl: false
              });
              L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
                maxZoom: 18
              }).addTo(map);
              this._map = map;
              this._renderData(data);
            },
            updated() {
              if (!this._map) return;
              const data = JSON.parse(this.el.dataset.mapdata || '{}');
              this._map.eachLayer(function(layer) {
                if (!(layer instanceof L.TileLayer)) layer.remove();
              });
              this._renderData(data);
            },
            _renderData(data) {
              const map = this._map;
              (data.terminals || []).forEach(function(t) {
                L.circleMarker([t.lat, t.lon], {
                  radius: 7, fillColor: t.color || '#38bdf8', fillOpacity: 0.85,
                  color: '#e2e8f0', weight: 1.5
                }).bindPopup('<b>' + t.name + '</b>').addTo(map);
              });
              (data.routes || []).forEach(function(r) {
                L.polyline([[r.from_lat, r.from_lon], [r.to_lat, r.to_lon]], {
                  color: r.active ? '#10b981' : '#334155',
                  weight: r.active ? 3 : 1.5,
                  dashArray: r.active ? null : '6 4',
                  opacity: r.active ? 0.9 : 0.4
                }).addTo(map);
              });
              (data.vessels || []).forEach(function(v) {
                var icon = L.divIcon({
                  html: '<div style="color:' + (v.color || '#f59e0b') + ';font-size:16px;line-height:1">&#9650;</div>',
                  iconSize: [16, 16], className: ''
                });
                L.marker([v.lat, v.lon], {icon: icon})
                  .bindPopup('<b>' + v.name + '</b><br>' + (v.status || ''))
                  .addTo(map);
              });
            }
          }

          // Scenario description: chip-click insertion + @ autocomplete
          Hooks.ScenarioDescription = {
            mounted() {
              this._corpus = JSON.parse(this.el.dataset.corpus || '[]');
              this._dropdown = null;
              this._ddItems  = [];
              this._ddIdx    = 0;
              this._atPos    = -1;

              // Textarea is identified by data-textarea attribute
              const taId = this.el.dataset.textarea;
              this._ta = taId ? document.getElementById(taId) : this.el.querySelector('textarea');
              if (!this._ta) return;

              // --- Chip click: event delegation on the wrapper ---
              this.el.addEventListener('click', (e) => {
                const chip = e.target.closest('.insert-chip');
                if (chip) {
                  e.preventDefault();
                  this._insertText(chip.dataset.insert || '');
                }
              });

              // --- @ trigger: autocomplete dropdown ---
              this._ta.addEventListener('input', () => this._onInput());
              this._ta.addEventListener('keydown', (e) => this._onKeydown(e));
              this._ta.addEventListener('blur', () => {
                // Small delay so mousedown on a dropdown item fires first
                setTimeout(() => this._hideDropdown(), 160);
              });
            },

            updated() {
              this._corpus = JSON.parse(this.el.dataset.corpus || '[]');
            },

            _insertText(text) {
              const ta = this._ta;
              if (!ta) return;
              const start = ta.selectionStart;
              const end   = ta.selectionEnd;
              const before = ta.value.substring(0, start);
              const after  = ta.value.substring(end);
              const sep    = (before.length > 0 && !/\s$/.test(before)) ? ' ' : '';
              ta.value = before + sep + text + ' ' + after;
              const newPos = before.length + sep.length + text.length + 1;
              ta.focus();
              ta.setSelectionRange(newPos, newPos);
              this.pushEvent('update_scenario_description', {description: ta.value});
            },

            _onInput() {
              const ta   = this._ta;
              const pos  = ta.selectionStart;
              const before = ta.value.substring(0, pos);
              // Find last @ that hasn't been followed by whitespace
              const m = before.match(/@([^@\s]*)$/);
              if (m) {
                this._atPos = before.lastIndexOf('@');
                this._showDropdown(m[1].toLowerCase());
              } else {
                this._hideDropdown();
              }
            },

            _onKeydown(e) {
              if (!this._dropdown) return;
              if (e.key === 'ArrowDown') {
                e.preventDefault();
                this._ddIdx = Math.min(this._ddIdx + 1, this._ddItems.length - 1);
                this._highlightItem();
              } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                this._ddIdx = Math.max(this._ddIdx - 1, 0);
                this._highlightItem();
              } else if (e.key === 'Enter') {
                if (this._ddItems.length > 0) {
                  e.preventDefault();
                  this._selectItem(this._ddIdx);
                }
              } else if (e.key === 'Escape') {
                this._hideDropdown();
              }
            },

            _showDropdown(query) {
              const matches = this._corpus.filter(item =>
                query === '' || (item.label || '').toLowerCase().includes(query)
              ).slice(0, 10);

              this._ddItems = matches;
              this._ddIdx   = 0;

              if (matches.length === 0) { this._hideDropdown(); return; }

              if (!this._dropdown) {
                this._dropdown = document.createElement('div');
                this._dropdown.style.cssText =
                  'position:fixed;z-index:99999;background:#111827;border:1px solid #2d3748;' +
                  'border-radius:8px;box-shadow:0 8px 32px rgba(0,0,0,0.7);min-width:280px;' +
                  'max-height:260px;overflow-y:auto;';
                document.body.appendChild(this._dropdown);
              }

              const rect = this._ta.getBoundingClientRect();
              this._dropdown.style.left  = rect.left + 'px';
              this._dropdown.style.top   = (rect.bottom + 4) + 'px';

              this._renderDropdown(matches);
            },

            _renderDropdown(items) {
              if (!this._dropdown) return;
              const typeColor = {variable:'#94a3b8', route:'#34d399', counterparty:'#c4b5fd', vessel:'#fcd34d'};
              const typeBg    = {variable:'#0d1526', route:'#071a12', counterparty:'#130d27', vessel:'#1a1408'};
              this._dropdown.innerHTML = items.map((item, i) => {
                const col = typeColor[item.type] || '#94a3b8';
                const bg  = i === this._ddIdx ? '#1e293b' : 'transparent';
                return `<div data-idx="${i}" style="padding:8px 14px;cursor:pointer;display:flex;` +
                  `justify-content:space-between;align-items:center;background:${bg};` +
                  `border-bottom:1px solid #1a2235;">` +
                  `<span style="color:${col};font-weight:600;font-size:13px">${item.label}</span>` +
                  `<span style="color:#7b8fa4;font-size:11px;margin-left:12px">${item.hint || item.group}</span>` +
                  `</div>`;
              }).join('');

              this._dropdown.querySelectorAll('[data-idx]').forEach(el => {
                el.addEventListener('mousedown', (e) => {
                  e.preventDefault();
                  this._selectItem(parseInt(el.dataset.idx, 10));
                });
              });
            },

            _highlightItem() {
              if (!this._dropdown) return;
              this._dropdown.querySelectorAll('[data-idx]').forEach((el, i) => {
                el.style.background = i === this._ddIdx ? '#1e293b' : 'transparent';
              });
            },

            _selectItem(idx) {
              const item = this._ddItems[idx];
              if (!item) return;
              const ta     = this._ta;
              const before = ta.value.substring(0, this._atPos);
              const after  = ta.value.substring(ta.selectionStart);
              ta.value = before + item.insert + ' ' + after;
              const newPos = before.length + item.insert.length + 1;
              ta.focus();
              ta.setSelectionRange(newPos, newPos);
              this.pushEvent('update_scenario_description', {description: ta.value});
              this._hideDropdown();
            },

            _hideDropdown() {
              if (this._dropdown) {
                this._dropdown.remove();
                this._dropdown = null;
                this._ddItems  = [];
              }
            }
          }

          // Theme toggle
          window.toggleTheme = function() {
            var isLight = document.documentElement.classList.toggle('theme-light');
            localStorage.setItem('td-theme', isLight ? 'light' : 'dark');
          };

          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: {_csrf_token: csrfToken},
            hooks: Hooks
          })
          liveSocket.connect()
        })
      </script>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        button:disabled { opacity: 0.5; cursor: not-allowed; }
        input:focus, button:focus { outline: 2px solid #38bdf8; outline-offset: 2px; }
        /* Light theme — invert the dark theme colours while preserving hues */
        html.theme-light body { filter: invert(1) hue-rotate(180deg); }
        /* Counter-invert media (images, video) so they stay natural */
        html.theme-light img,
        html.theme-light video,
        html.theme-light canvas { filter: invert(1) hue-rotate(180deg); }
      </style>
    </head>
    <body>
      <%= @inner_content %>
    </body>
    </html>
    """
  end
end
