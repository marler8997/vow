pub const Depth = x11.Depth;
pub const KeycodeRange = x11.KeycodeRange;
pub const RequestSink = x11.RequestSink;
pub const ResourceBase = x11.ResourceBase;
pub const Screen = x11.Screen;
pub const Source = x11.Source;
pub const Window = x11.Window;
pub const Visual = x11.Visual;

pub const disconnect = x11.disconnect;
pub const draft = x11.draft;
pub const readSetupSuccess = x11.readSetupSuccess;
pub const socketWriter = x11.socketWriter;
pub const socketReader = x11.socketReader;
pub const synchronousGetKeyboardMapping = x11.synchronousGetKeyboardMapping;

pub const Ids = struct {
    base: ResourceBase,
    pub fn window(self: Ids) Window {
        return self.base.add(0).window();
    }
};
pub const Root = struct {
    window: Window,
    visual: Visual,
    depth: Depth,
};

const x11 = @import("x11");
