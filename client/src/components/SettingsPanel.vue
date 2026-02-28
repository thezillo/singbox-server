<script setup lang="ts">
import { ref, watch } from "vue";
import { useConnectionStore } from "../stores/connection";

const store = useConnectionStore();

const configUrl = ref(store.settings.config_url);
const refreshInterval = ref(store.settings.refresh_interval_min);

watch(() => store.settings.config_url, (v) => (configUrl.value = v));
watch(() => store.settings.refresh_interval_min, (v) => (refreshInterval.value = v));

async function save() {
  await store.saveSettings(configUrl.value, refreshInterval.value);
  store.settingsOpen = false;
}
</script>

<template>
  <div class="settings-overlay" :class="{ open: store.settingsOpen }" @click="store.settingsOpen = false" />
  <div class="settings-panel" :class="{ open: store.settingsOpen }">
    <div class="settings-card">
      <div class="settings-card-title">Settings</div>
      <div class="settings-field">
        <label>Config URL</label>
        <input
          v-model="configUrl"
          type="text"
          placeholder="https://vpn:pass@server:port/path/config.json"
          spellcheck="false"
          autocomplete="off"
        />
      </div>
      <div class="settings-field">
        <label>Auto-refresh (min)</label>
        <input v-model.number="refreshInterval" type="number" min="1" max="1440" />
      </div>
      <div class="settings-actions">
        <button class="cancel-btn" @click="store.settingsOpen = false">Cancel</button>
        <button class="save-btn" @click="save">Save</button>
      </div>
    </div>
  </div>
</template>
