# Chiller Room: how to preview

## Open the preview
1. Open the **Terminal** app (press Cmd+Space, type `Terminal`, press Return).
2. Paste this line and press Return:

   ```
   cd ~/chiller-room && ~/.rive/bin/rive .
   ```

3. A window opens with the 3D room. Leave Terminal open while you use it.

## Controls
- **Click the room once** so it has focus.
- **W**: walk forward
- **S**: walk back
- **Q**: step left
- **E**: step right
- **Space** (hold): walk faster
- **Left / Right arrows**: turn
- **Up / Down arrows**: look up / down

## Close it
Close the preview window, or click in Terminal and press **Ctrl+C**.

## If something goes wrong
- **"command not found"**: copy the line again exactly, including `~/.rive/bin/rive`.
- **Keys do nothing**: click inside the room window, then try again.
- **Black or empty window**: look in Terminal for red `error` lines and paste them to Claude.
