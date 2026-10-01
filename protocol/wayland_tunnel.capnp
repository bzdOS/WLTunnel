@0xd1e2f3a4b5c60718;

# bsdOS Universal Wayland Tunnel — Zero-Copy протокол.
# Перехватывает сырой Wayland binary stream без парсинга.
# Любое Wayland-приложение (Chrome, terminal, Plasma) работает через этот тоннель.

# Пакет Wayland протокола (raw bytes, zero-copy)
# Wire: [framing][struct_ptr:dataWords=2,ptrWords=1][msgId][objId+opCode][list_ptr][payload]
struct WaylandPacket {
  messageId @0 :UInt32;  # монотонный счётчик для ordering
  objectId  @1 :UInt32;  # Wayland object ID (из заголовка сообщения)
  opCode    @2 :UInt16;  # Wayland opcode (из заголовка сообщения)
  payload   @3 :Data;    # сырые байты Wayland message (including header)
}

# Событие ввода от клиента (мышь/клавиатура) → сервер
# Фиксированный размер, zero-copy через 4-байтовый fast path
struct ClientInput {
  type    @0 :UInt8;   # 0=pointer_move 1=button 2=key 3=scroll
  x       @1 :UInt16;
  y       @2 :UInt16;
  details @3 :UInt32;  # кнопка/keycode/scroll delta
}
