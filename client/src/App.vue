<script setup lang="ts">
import { onMounted } from "vue";
import { useConnectionStore } from "./stores/connection";
import HeaderBar from "./components/HeaderBar.vue";
import SettingsPanel from "./components/SettingsPanel.vue";
import ConnectionToggle from "./components/ConnectionToggle.vue";
import TrafficStats from "./components/TrafficStats.vue";
import ConfigInfo from "./components/ConfigInfo.vue";

const store = useConnectionStore();

onMounted(() => {
  store.init();
});
</script>

<template>
  <HeaderBar />
  <SettingsPanel />
  <div class="main-content">
    <ConnectionToggle />
    <TrafficStats />
  </div>
  <div class="bottom-section">
    <div v-if="store.error" class="error-bar">{{ store.error }}</div>
    <ConfigInfo />
  </div>
</template>
