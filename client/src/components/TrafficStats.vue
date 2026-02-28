<script setup lang="ts">
import { ref, watch, onUnmounted, computed } from "vue";
import { useConnectionStore } from "../stores/connection";

const store = useConnectionStore();

const MAX_POINTS = 60;
const upHistory = ref<number[]>(new Array(MAX_POINTS).fill(0));
const downHistory = ref<number[]>(new Array(MAX_POINTS).fill(0));
const canvas = ref<HTMLCanvasElement | null>(null);

function formatSpeed(bytes: number): string {
  if (bytes < 1024) return `${bytes} B/s`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB/s`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB/s`;
}

const upSpeed = computed(() => formatSpeed(store.traffic.up_speed));
const downSpeed = computed(() => formatSpeed(store.traffic.down_speed));

function pushPoint() {
  upHistory.value.push(store.traffic.up_speed);
  downHistory.value.push(store.traffic.down_speed);
  if (upHistory.value.length > MAX_POINTS) upHistory.value.shift();
  if (downHistory.value.length > MAX_POINTS) downHistory.value.shift();
  draw();
}

function draw() {
  const c = canvas.value;
  if (!c) return;
  const ctx = c.getContext("2d")!;
  if (!ctx) return;

  const dpr = window.devicePixelRatio || 1;
  const w = c.clientWidth;
  const h = c.clientHeight;
  c.width = w * dpr;
  c.height = h * dpr;
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, w, h);

  const allVals = [...upHistory.value, ...downHistory.value];
  const peak = Math.max(...allVals, 1024);

  function drawLine(data: number[], color: string, fillColor: string) {
    const step = w / (MAX_POINTS - 1);
    ctx.beginPath();
    for (let i = 0; i < data.length; i++) {
      const x = i * step;
      const y = h - (data[i] / peak) * (h * 0.85) - 1;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.5;
    ctx.stroke();

    // Fill area
    ctx.lineTo((data.length - 1) * step, h);
    ctx.lineTo(0, h);
    ctx.closePath();
    ctx.fillStyle = fillColor;
    ctx.fill();
  }

  drawLine(upHistory.value, "rgba(139, 92, 246, 0.7)", "rgba(139, 92, 246, 0.08)");
  drawLine(downHistory.value, "rgba(45, 212, 160, 0.7)", "rgba(45, 212, 160, 0.08)");
}

const stopWatch = watch(
  () => store.traffic.up_speed + store.traffic.down_speed,
  () => pushPoint()
);

watch(
  () => store.isConnected,
  (connected) => {
    if (!connected) {
      upHistory.value = new Array(MAX_POINTS).fill(0);
      downHistory.value = new Array(MAX_POINTS).fill(0);
      draw();
    }
  }
);

onUnmounted(() => stopWatch());
</script>

<template>
  <div class="traffic-chart" v-if="store.isConnected">
    <canvas ref="canvas" class="traffic-canvas"></canvas>
    <div class="traffic-legend">
      <span class="legend-item up">
        <span class="legend-dot"></span>
        ↑ {{ upSpeed }}
      </span>
      <span class="legend-item down">
        <span class="legend-dot"></span>
        ↓ {{ downSpeed }}
      </span>
    </div>
  </div>
</template>

<style scoped>
.traffic-chart {
  width: 100%;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.traffic-canvas {
  display: block;
  width: 100%;
  height: 48px;
}

.traffic-legend {
  display: flex;
  justify-content: center;
  gap: 16px;
  font-size: 11px;
  color: var(--text-muted);
  font-variant-numeric: tabular-nums;
}

.legend-item {
  display: flex;
  align-items: center;
  gap: 4px;
}

.legend-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
}

.legend-item.up .legend-dot {
  background: var(--purple);
}

.legend-item.down .legend-dot {
  background: var(--accent);
}
</style>
