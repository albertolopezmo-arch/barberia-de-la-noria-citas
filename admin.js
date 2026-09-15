const CFG = window.FLORIDO_CONFIG;
const apiBase = `${CFG.SUPABASE_URL}/rest/v1`;
const authBase = `${CFG.SUPABASE_URL}/auth/v1`;
const publicHeaders = { apikey: CFG.SUPABASE_ANON_KEY, "Content-Type": "application/json" };
const todayValue = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const dateField = document.querySelector("#admin-date");
let session = JSON.parse(sessionStorage.getItem("florido-admin-session") || "null");
let pendingCancellation = null;
let currentAppointments = [];
let currentSlots = [];
let services = [];
let completionTimer = null;

function authHeaders(extra = {}) {
  return { ...publicHeaders, Authorization: `Bearer ${session?.access_token || ""}`, ...extra };
}

async function request(url, options = {}) {
  const response = await fetch(url, options);
  if (response.status === 401 || response.status === 403) {
    logout();
    throw new Error("Sesión no autorizada");
  }
  const text = await response.text();
  if (!response.ok) throw new Error(text || "Operación no disponible");
  return text ? JSON.parse(text) : null;
}

function showDashboard() {
  document.querySelector("#login-view").hidden = true;
  document.querySelector("#dashboard-view").hidden = false;
  document.querySelector("#logout-button").hidden = false;
  dateField.value = todayValue;
  loadServices();
  loadDay();
  clearInterval(completionTimer);
  completionTimer = setInterval(() => renderAppointments(currentAppointments), 30000);
}

function logout() {
  session = null;
  sessionStorage.removeItem("florido-admin-session");
  document.querySelector("#login-view").hidden = false;
  document.querySelector("#dashboard-view").hidden = true;
  document.querySelector("#logout-button").hidden = true;
  clearInterval(completionTimer);
}

document.querySelector("#login-form").addEventListener("submit", async event => {
  event.preventDefault();
  const error = document.querySelector("#login-error");
  error.textContent = "";
  const button = event.submitter;
  button.disabled = true;
  try {
    session = await request(`${authBase}/token?grant_type=password`, {
      method: "POST",
      headers: publicHeaders,
      body: JSON.stringify({
        email: document.querySelector("#admin-email").value.trim(),
        password: document.querySelector("#admin-password").value
      })
    });
    const isAdmin = await request(`${apiBase}/rpc/is_florido_admin`, {
      method: "POST",
      headers: authHeaders(),
      body: "{}"
    });
    if (isAdmin !== true) {
      session = null;
      throw new Error("Usuario sin permiso de administrador");
    }
    sessionStorage.setItem("florido-admin-session", JSON.stringify(session));
    showDashboard();
  } catch {
    error.textContent = "Correo, contraseña o permisos incorrectos.";
  } finally {
    button.disabled = false;
  }
});

function prettyDate(value) {
  return new Intl.DateTimeFormat("es-ES", { weekday: "long", day: "numeric", month: "long", year: "numeric" })
    .format(new Date(`${value}T12:00:00`));
}

async function loadDay() {
  const date = dateField.value || todayValue;
  document.querySelector("#day-label").textContent = prettyDate(date);
  document.querySelector("#appointments-list").innerHTML = '<p class="empty-admin">Cargando citas…</p>';
  try {
    const [appointments, blocks, slots] = await Promise.all([
      request(`${apiBase}/appointments?select=id,customer_name,phone,service,appointment_time,price_eur,status&appointment_date=eq.${date}&status=eq.confirmed&order=appointment_time.asc`, { headers: authHeaders() }),
      request(`${apiBase}/blocked_slots?select=id,block_time,reason&block_date=eq.${date}&order=block_time.asc.nullsfirst`, { headers: authHeaders() }),
      request(`${apiBase}/rpc/get_available_slots`, { method: "POST", headers: authHeaders(), body: JSON.stringify({ p_date: date }) })
    ]);
    currentAppointments = appointments || [];
    currentSlots = slots || [];
    renderAppointments(currentAppointments);
    renderBlocks(blocks || []);
    document.querySelector("#confirmed-count").textContent = appointments.length;
    document.querySelector("#available-count").textContent = slots.length;
    const revenue = currentAppointments.reduce((total, item) => total + Number(item.price_eur || 0), 0);
    document.querySelector("#revenue-count").textContent = `${revenue.toFixed(2).replace(".00", "")} €`;
  } catch {
    document.querySelector("#appointments-list").innerHTML = '<p class="empty-admin">No se pudo cargar la agenda. Comprueba la sesión.</p>';
  }
}

function renderAppointments(items) {
  const list = document.querySelector("#appointments-list");
  if (!items.length) {
    list.innerHTML = '<p class="empty-admin">No hay citas confirmadas para este día.</p>';
    return;
  }
  list.innerHTML = "";
  items.forEach(item => {
    const row = document.createElement("article");
    const completed = appointmentHasPassed(dateField.value, item.appointment_time);
    row.className = `appointment${completed ? " completed" : ""}`;
    row.innerHTML = `<div class="appointment-time">${item.appointment_time.slice(0,5)}</div><div><strong></strong><span></span><span></span>${completed ? '<span class="appointment-status">✓ Cliente atendido</span>' : ""}</div><button class="cancel-button" type="button">Cancelar cita</button>`;
    row.querySelector("strong").textContent = item.customer_name;
    row.querySelectorAll("span")[0].textContent = `${item.service} · ${Number(item.price_eur || 0).toFixed(2).replace(".00", "")} €`;
    row.querySelectorAll("span")[1].textContent = item.phone;
    row.querySelector("button").addEventListener("click", () => askCancel(item));
    list.appendChild(row);
  });
}

function madridNowKey() {
  const parts = new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Europe/Madrid", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23"
  }).formatToParts(new Date()).reduce((result, part) => ({ ...result, [part.type]: part.value }), {});
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`;
}

function appointmentHasPassed(date, time) {
  return `${date}T${String(time).slice(0, 5)}` <= madridNowKey();
}

function askCancel(item) {
  pendingCancellation = item;
  document.querySelector("#cancel-text").textContent = `${item.customer_name} · ${item.appointment_time.slice(0,5)} · ${item.service}`;
  document.querySelector("#cancel-dialog").showModal();
}

document.querySelector("#dismiss-cancel").addEventListener("click", () => document.querySelector("#cancel-dialog").close());
document.querySelector("#confirm-cancel").addEventListener("click", async () => {
  if (!pendingCancellation) return;
  const button = document.querySelector("#confirm-cancel");
  button.disabled = true;
  try {
    await request(`${apiBase}/appointments?id=eq.${pendingCancellation.id}`, {
      method: "PATCH", headers: authHeaders({ Prefer: "return=minimal" }), body: JSON.stringify({ status: "cancelled" })
    });
    document.querySelector("#cancel-dialog").close();
    pendingCancellation = null;
    await loadDay();
  } finally { button.disabled = false; }
});

document.querySelector("#block-form").addEventListener("submit", async event => {
  event.preventDefault();
  const error = document.querySelector("#block-error");
  error.textContent = "";
  const time = document.querySelector("#block-time").value;
  try {
    await request(`${apiBase}/blocked_slots`, {
      method: "POST",
      headers: authHeaders({ Prefer: "return=minimal" }),
      body: JSON.stringify({ block_date: dateField.value, block_time: time ? `${time}:00` : null, reason: document.querySelector("#block-reason").value.trim() || null })
    });
    event.target.reset();
    await loadDay();
  } catch { error.textContent = "Ese día o esa hora ya están bloqueados."; }
});

const manualDialog = document.querySelector("#manual-booking-dialog");
const manualForm = document.querySelector("#manual-booking-form");
const manualTime = document.querySelector("#manual-time");
const saveManual = document.querySelector("#save-manual");

document.querySelector("#open-manual-booking").addEventListener("click", async () => {
  const date = dateField.value || todayValue;
  document.querySelector("#manual-date-label").textContent = `Cita para el ${prettyDate(date)}`;
  document.querySelector("#manual-error").textContent = "";
  manualForm.reset();
  fillServiceSelect(document.querySelector("#manual-service"));
  manualTime.value = "";
  manualTime.disabled = false;
  saveManual.disabled = false;
  manualDialog.showModal();
});

document.querySelector("#dismiss-manual").addEventListener("click", () => manualDialog.close());

manualForm.addEventListener("submit", async event => {
  event.preventDefault();
  const error = document.querySelector("#manual-error");
  error.textContent = "";
  const name = document.querySelector("#manual-name").value.trim();
  const phone = document.querySelector("#manual-phone").value.trim() || "Sin teléfono";
  if (name.length < 2 || !manualTime.value) return;
  saveManual.disabled = true;
  try {
    const selected = services.find(item => item.name === document.querySelector("#manual-service").value);
    await request(`${apiBase}/appointments`, {
      method: "POST",
      headers: authHeaders({ Prefer: "return=minimal" }),
      body: JSON.stringify({
        customer_name: name,
        phone,
        service: document.querySelector("#manual-service").value,
        appointment_date: dateField.value,
        appointment_time: `${manualTime.value}:00`,
        price_eur: Number(selected?.price_eur || 0),
        status: "confirmed"
      })
    });
    manualDialog.close();
    await loadDay();
  } catch {
    error.textContent = "No se pudo guardar. Comprueba que la hora siga libre y que el nombre sea correcto.";
  } finally {
    saveManual.disabled = false;
  }
});

function renderBlocks(items) {
  const list = document.querySelector("#blocks-list");
  if (!items.length) { list.innerHTML = '<p class="hint">No hay bloqueos.</p>'; return; }
  list.innerHTML = "";
  items.forEach(item => {
    const row = document.createElement("div");
    row.className = "block-row";
    const label = item.block_time ? `${item.block_time.slice(0,5)}${item.reason ? ` · ${item.reason}` : ""}` : `Día completo${item.reason ? ` · ${item.reason}` : ""}`;
    row.innerHTML = '<span></span><button class="unblock-button" type="button">Volver a abrir</button>';
    row.querySelector("span").textContent = label;
    row.querySelector("button").addEventListener("click", async () => {
      await request(`${apiBase}/blocked_slots?id=eq.${item.id}`, { method: "DELETE", headers: authHeaders() });
      await loadDay();
    });
    list.appendChild(row);
  });
}

function fillServiceSelect(select) {
  select.innerHTML = "";
  services.filter(item => item.active).forEach(item => {
    const option = document.createElement("option");
    option.value = item.name;
    option.textContent = `${item.name} · ${Number(item.price_eur).toFixed(2).replace(".00", "")} €`;
    select.appendChild(option);
  });
}

async function loadServices() {
  try {
    services = await request(`${apiBase}/florido_services?select=id,name,price_eur,duration_minutes,active&order=sort_order.asc,name.asc`, { headers: authHeaders() }) || [];
    renderServices();
  } catch {
    document.querySelector("#services-list").innerHTML = '<p class="empty-admin">Ejecuta primero la actualización de Supabase para gestionar servicios.</p>';
  }
}

function renderServices() {
  const list = document.querySelector("#services-list");
  list.innerHTML = "";
  services.forEach(service => {
    const row = document.createElement("article");
    row.className = `service-admin-row${service.active ? "" : " inactive"}`;
    row.innerHTML = '<div><strong></strong><span></span></div><button class="small-action edit-service" type="button">Editar</button><button class="small-action toggle-service" type="button"></button>';
    row.querySelector("strong").textContent = service.name;
    row.querySelector("span").textContent = `${Number(service.price_eur).toFixed(2).replace(".00", "")} € · ${service.duration_minutes} minutos`;
    row.querySelector(".toggle-service").textContent = service.active ? "Ocultar" : "Activar";
    row.querySelector(".edit-service").addEventListener("click", () => openServiceDialog(service));
    row.querySelector(".toggle-service").addEventListener("click", async () => {
      await request(`${apiBase}/florido_services?id=eq.${service.id}`, { method: "PATCH", headers: authHeaders({ Prefer: "return=minimal" }), body: JSON.stringify({ active: !service.active }) });
      await loadServices();
    });
    list.appendChild(row);
  });
}

const serviceDialog = document.querySelector("#service-dialog");
function openServiceDialog(service = null) {
  document.querySelector("#service-form").reset();
  document.querySelector("#service-id").value = service?.id || "";
  document.querySelector("#service-name").value = service?.name || "";
  document.querySelector("#service-price").value = service?.price_eur ?? "";
  document.querySelector("#service-duration").value = service?.duration_minutes || 60;
  document.querySelector("#service-dialog-title").textContent = service ? "Editar servicio" : "Añadir servicio";
  document.querySelector("#service-error").textContent = "";
  serviceDialog.showModal();
}

document.querySelector("#add-service").addEventListener("click", () => openServiceDialog());
document.querySelector("#dismiss-service").addEventListener("click", () => serviceDialog.close());
document.querySelector("#service-form").addEventListener("submit", async event => {
  event.preventDefault();
  const id = document.querySelector("#service-id").value;
  const payload = {
    name: document.querySelector("#service-name").value.trim(),
    price_eur: Number(document.querySelector("#service-price").value),
    duration_minutes: Number(document.querySelector("#service-duration").value)
  };
  try {
    await request(`${apiBase}/florido_services${id ? `?id=eq.${id}` : ""}`, {
      method: id ? "PATCH" : "POST", headers: authHeaders({ Prefer: "return=minimal" }), body: JSON.stringify(payload)
    });
    serviceDialog.close();
    await loadServices();
  } catch { document.querySelector("#service-error").textContent = "No se pudo guardar. Comprueba el nombre y el precio."; }
});

const availableDialog = document.querySelector("#available-dialog");
document.querySelector("#show-available-slots").addEventListener("click", () => {
  const date = dateField.value || todayValue;
  document.querySelector("#available-date-label").textContent = prettyDate(date);
  const list = document.querySelector("#available-slots-list");
  list.innerHTML = currentSlots.length
    ? currentSlots.map(item => `<span>${String(item.slot_time).slice(0, 5)}</span>`).join("")
    : '<p class="empty-admin">No quedan huecos disponibles.</p>';
  availableDialog.showModal();
});
document.querySelector("#close-available").addEventListener("click", () => availableDialog.close());

dateField.addEventListener("change", loadDay);
document.querySelector("#refresh-button").addEventListener("click", loadDay);
document.querySelector("#logout-button").addEventListener("click", logout);
if (session?.access_token) showDashboard();
