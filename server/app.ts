import { Hono } from "hono";
import { createRequestHandler } from "react-router";

import * as build from "virtual:react-router/server-build";

const app = new Hono();
const handler = createRequestHandler(build);

app.mount("/", (request) => handler(request));

export default app.fetch;
