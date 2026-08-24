// Stands in for teams-for-linux against omarchy-teams-bridge.
//
// Mirrors what the real app does in mqtt/index.js: connect with a last will on
// <prefix>/connected, publish retained status and media topics, subscribe to the
// command topic, and finally drop the socket without a DISCONNECT so the will
// has to fire. Run by test/run.sh.

const mqtt = require("mqtt");

const PORT = Number(process.env.BRIDGE_PORT || 18830);
const PREFIX = "teams";
const step = (name) => console.log(`STEP ${name}`);

const client = mqtt.connect(`mqtt://127.0.0.1:${PORT}`, {
  clientId: "teams-for-linux",
  will: { topic: `${PREFIX}/connected`, payload: "false", qos: 0, retain: true },
});

client.on("error", (err) => {
  console.log(`ERROR ${err.message}`);
  process.exit(1);
});

client.on("connect", async () => {
  step("connected");
  client.publish(`${PREFIX}/connected`, "true", { retain: true });

  client.subscribe(`${PREFIX}/command`, (err) => {
    if (err) {
      console.log(`ERROR subscribe ${err.message}`);
      process.exit(1);
    }
    step("subscribed");
  });

  // The real publishStatus() payload shape.
  client.publish(
    `${PREFIX}/status`,
    JSON.stringify({
      status: "busy",
      statusCode: 2,
      timestamp: "2026-08-24T12:00:00.000Z",
      clientId: "teams-for-linux",
    }),
    { retain: true },
  );
  client.publish(`${PREFIX}/in-call`, "true", { retain: true });
  client.publish(`${PREFIX}/microphone`, "muted", { retain: true });
  client.publish(`${PREFIX}/screen-sharing`, "true", { retain: true });
  // QoS 1 exercises the PUBACK path.
  client.publish(`${PREFIX}/camera`, "true", { retain: true, qos: 1 });
  step("published");
});

client.on("message", (topic, payload) => {
  console.log(`RECV ${topic} ${payload.toString()}`);
  if (topic === `${PREFIX}/command`) {
    // Hard-kill the socket: no DISCONNECT packet, so the broker must publish
    // the will. This is what happens when Teams crashes or is SIGKILLed.
    step("dropping");
    client.stream.destroy();
    setTimeout(() => process.exit(0), 300);
  }
});
