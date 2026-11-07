import { expect, type APIRequestContext, type Page } from "@playwright/test";
import path from "node:path";

export const ECHO_PLUGIN = path.resolve(__dirname, "../../test/fixtures/echo.sdPlugin");
export const ECHO_ACTION = "com.example.echo.action";

const json = { "content-type": "application/json" };

export type Key = {
  column: number;
  row: number;
  action: string;
  context: string;
  settings: Record<string, unknown>;
  title: string | null;
  feedback: "ok" | "alert" | null;
};

/** Loads a plugin (replacing the current one) and waits until it connects. */
export async function loadPlugin(request: APIRequestContext, pluginPath: string) {
  const response = await request.post("/api/plugin", { headers: json, data: { path: pluginPath } });
  expect(response.ok(), await response.text()).toBeTruthy();
  await expect.poll(async () => (await state(request)).plugin?.connected).toBe(true);
}

export async function unloadPlugin(request: APIRequestContext) {
  await request.delete("/api/plugin", { headers: json });
}

export async function state(request: APIRequestContext) {
  return (await request.get("/api/state")).json();
}

export async function key(request: APIRequestContext, column: number, row: number): Promise<Key | undefined> {
  const { keys } = await state(request);
  return keys.find((k: Key) => k.column === column && k.row === row);
}

/** Places an action on a key through the API and returns the key. */
export async function placeAction(
  request: APIRequestContext,
  column: number,
  row: number,
  action: string,
  settings: Record<string, unknown> = {},
): Promise<Key> {
  const response = await request.put(`/api/keys/${column}/${row}`, { headers: json, data: { action, settings } });
  expect(response.ok(), await response.text()).toBeTruthy();
  return response.json();
}

/** The key's button in the UI. Clicking it sends keyDown, then keyUp. */
export function keyButton(page: Page, column: number, row: number) {
  return page.locator(`#key-${column}-${row}`);
}

export function keyTitle(page: Page, column: number, row: number) {
  return keyButton(page, column, row).locator("[data-role=title]");
}

/** An action in the UI's action list. Clicking it places it on the selected key. */
export function actionButton(page: Page, action: string) {
  return page.locator(`[id="action-${action}"]`);
}

/** The Property Inspector of the selected key. */
export function propertyInspector(page: Page) {
  return page.frameLocator("iframe[title='Property Inspector']");
}
