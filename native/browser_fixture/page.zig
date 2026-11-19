pub const html =
    \\<!doctype html>
    \\<html lang="en">
    \\<meta charset="utf-8">
    \\<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
    \\<title>ChatPalette offline fixture</title>
    \\<main>
    \\  <h1>ChatPalette offline fixture</h1>
    \\  <div class="yt-live-chat-text-input-field-renderer"><input id="input" aria-label="Chat"></div>
    \\  <div class="ytd-comment-simplebox-renderer"><div id="comment" contenteditable="true" role="textbox" aria-label="Add a comment"></div></div>
    \\  <input id="search" aria-label="Search">
    \\  <div class="yt-live-chat" style="position:fixed;right:30px;top:220px">
    \\    <button id="reaction-control-panel" class="yt-reaction-control-panel" aria-label="Show reactions">Open</button>
    \\    <div id="reaction-menu" role="group" aria-label="Reaction choices" hidden>
    \\      <button id="fixture-heart" aria-label="Heart">Heart</button>
    \\      <button id="fixture-smile">Smile</button>
    \\      <button id="fixture-party">Party</button>
    \\      <button id="fixture-wow">Wow</button>
    \\      <button id="fixture-hundred">100</button>
    \\    </div>
    \\  </div>
    \\</main>
    \\<script>
    \\  let chat = document.getElementById('input');
    \\  let retiredChat = null;
    \\  let secondChat = null;
    \\  let focusFault = null;
    \\  const originalLocation = location.pathname + location.search;
    \\  const search = document.getElementById('search');
    \\  const comment = document.getElementById('comment');
    \\  const launcher = document.getElementById('reaction-control-panel');
    \\  const menu = document.getElementById('reaction-menu');
    \\  const events = [];
    \\  const reactions = [];
    \\  const pointers = [];
    \\  const wellFormed = value => value.replace(/[\ud800-\udfff]/gu, '\ufffd');
    \\  const fieldValue = field => wellFormed(field.value ?? field.textContent);
    \\  const modifiers = event => ({ ctrl: event.ctrlKey, alt: event.altKey, shift: event.shiftKey, meta: event.metaKey });
    \\  function track(field) {
    \\    field.addEventListener('focus', () => {
    \\      events.push({ type: 'focus', id: field.id });
    \\      if (field !== chat || focusFault === null) return;
    \\      const fault = focusFault;
    \\      focusFault = null;
    \\      if (fault === 'video') {
    \\        const url = new URL(location.href);
    \\        url.searchParams.set('v', 'ZigTest0002');
    \\        history.replaceState(null, '', url.pathname + url.search);
    \\        events.push({ type: 'video_replaced', id: field.id, value: 'ZigTest0002' });
    \\      } else if (fault === 'search') {
    \\        search.focus();
    \\        events.push({ type: 'focus_redirected', id: search.id });
    \\      } else {
    \\        retiredChat = field;
    \\        chat = field.cloneNode(false);
    \\        chat.value = 'REPLACEMENT';
    \\        track(chat);
    \\        retiredChat.replaceWith(chat);
    \\        events.push({ type: 'chat_replaced', id: chat.id, value: chat.value });
    \\        chat.focus();
    \\      }
    \\    });
    \\    field.addEventListener('input', () => events.push({ type: 'input', id: field.id, value: fieldValue(field) }));
    \\    for (const type of ['compositionstart', 'compositionupdate', 'compositionend']) {
    \\      field.addEventListener(type, event => events.push({ type, id: field.id, value: wellFormed(event.data ?? '') }));
    \\    }
    \\    field.addEventListener('keydown', event => {
    \\      events.push({ type: event.key, id: field.id, value: fieldValue(field), ...modifiers(event) });
    \\      if (event.key === 'Enter') event.preventDefault();
    \\    });
    \\    field.addEventListener('keyup', event => events.push({ type: 'keyup', id: field.id, key: event.key, ...modifiers(event) }));
    \\  }
    \\  track(chat);
    \\  track(search);
    \\  track(comment);
    \\  launcher.addEventListener('pointerenter', () => events.push({ type: 'launcher_hover', id: launcher.id }));
    \\  launcher.addEventListener('click', () => events.push({ type: 'launcher_click', id: launcher.id }));
    \\  function restore() {
    \\    focusFault = null;
    \\    if (location.pathname + location.search !== originalLocation) history.replaceState(null, '', originalLocation);
    \\    if (retiredChat !== null) {
    \\      chat.replaceWith(retiredChat);
    \\      chat = retiredChat;
    \\      retiredChat = null;
    \\    }
    \\    chat.hidden = false;
    \\    secondChat?.remove();
    \\    secondChat = null;
    \\    return true;
    \\  }
    \\  menu.addEventListener('click', event => {
    \\    if (event.target.tagName === 'BUTTON') reactions.push({ id: event.target.id, ms: performance.now(), click_count: event.detail });
    \\    event.preventDefault();
    \\  });
    \\  for (const type of ['pointerdown', 'pointerup']) {
    \\    document.addEventListener(type, event => {
    \\      pointers.push({ type, id: event.target.id, ms: performance.now(), x: event.screenX, y: event.screenY });
    \\    }, true);
    \\  }
    \\  window.fixture = {
    \\    identity: 'chatpalette-zig-offline-1',
    \\    reset(field, value) {
    \\      restore();
    \\      chat.value = value;
    \\      search.value = 'KEEP';
    \\      comment.textContent = 'KEEP_COMMENT';
    \\      document.getElementById(field).focus();
    \\      events.length = 0;
    \\      return true;
    \\    },
    \\    armFocusFault(kind) {
    \\      if (document.activeElement !== search || !['video', 'chat', 'search'].includes(kind)) return false;
    \\      focusFault = kind;
    \\      return true;
    \\    },
    \\    restore,
    \\    setChatCount(count) {
    \\      if (count === 0) chat.hidden = true;
    \\      if (count === 2) {
    \\        secondChat = chat.cloneNode(false);
    \\        secondChat.id = 'second-chat';
    \\        secondChat.setAttribute('aria-label', 'Type a message');
    \\        secondChat.value = 'KEEP_SECOND_CHAT';
    \\        track(secondChat);
    \\        chat.after(secondChat);
    \\      }
    \\      return true;
    \\    },
    \\    clearEvents() { events.length = 0; return true; },
    \\    showReactions(value) { menu.hidden = !value; return true; },
    \\    resetReactions() { reactions.length = 0; pointers.length = 0; return true; },
    \\    state() {
    \\      return {
    \\        active: document.activeElement.id, chat: wellFormed(chat.value), search: wellFormed(search.value),
    \\        comment: fieldValue(comment), second_chat: secondChat === null ? null : fieldValue(secondChat),
    \\        url: location.href, visible: document.visibilityState === 'visible', focused: document.hasFocus(),
    \\        video: new URLSearchParams(location.search).get('v') || '',
    \\        retired_chat: retiredChat === null ? null : wellFormed(retiredChat.value),
    \\        events: events.slice(), reactions: reactions.slice(), pointers: pointers.slice()
    \\      };
    \\    },
    \\  };
    \\</script>
    \\</html>
;
