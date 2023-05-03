const std = @import("std");
const json = @import("json");
const http = std.net.http;

const GPT35_API_URL = "https://api.openai.com/v1/engines/davinci-codex/completions";
const GPT4_API_URL = "https://api.openai.com/v1/engines/gpt-4/completions";
const EMBED_API_URL = "https://api.openai.com/v1/embeddings";

const api_key = std.os.getenv("OPENAI_API_KEY") orelse {
    std.debug.warn("OPENAI_API_KEY environment variable not set\n");
};

fn performRequest(allocator: *std.mem.Allocator, url: []const u8, payload: []const u8) ![]u8 {
    const client = http.Client.init(allocator);
    defer client.deinit();

    var request = try client.request(.{
        .method = .POST,
        .url = url,
        .headers = &[_]http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = "Bearer " ++ api_key },
        },
    });
    defer request.deinit();

    try request.writePayload(payload);

    const response = try request.readResponse();
    defer response.deinit();

    if (response.status_code != 200) {
        return error.RequestFailed;
    }

    const response_body = try response.readBody(allocator);
    return response_body;
}

fn getEmbedding(allocator: *std.mem.Allocator, text: []const u8) ![]u8 {
    const payload = try json.stringify(allocator, .{ .text = text });
    const response = try performRequest(allocator, EMBED_API_URL, payload);
    defer allocator.free(response);

    var stream = std.io.bufferedREader(response);
    const json_value = try json.parse(allocator, &stream, std.json.TokenStream, null);
    defer json_value.deinit();

    const data = try json_value.getObject("data");
    const first_data = try data.array().at(0);
    const embedding_json = try first_data.getObject("embedding");
    const embedding_array = try embedding_json.array();

    var embedding: []f64 = try allocator.alloc(f64, embedding_array.len);
    for (embedding_array) |value, i| {
        embedding[i] = try value.number();
    }

    return embedding;
}

fn getPromptResponse(allocator: *std.mem.Allocator, text: []const u8, gpt_version: u8) ![]u8 {
    const apiUrl = if (gpt_version == 3) GPT35_API_URL else GPT4_API_URL;
    const payload = try json.stringify(allocator, .{ .prompt = text, .max_tokens = 50 });
    const response = try performRequest(allocator, apiUrl, payload);
    defer allocator.free(response);

    var stream = std.io.bufferedREader(response);
    const json_value = try json.parse(allocator, &stream, std.json.TokenStream, null);
    defer json_value.deinit();

    const choices = try json_value.getArray("choices");
    const first_choice = try choices.array().at(0);
    const message = try first_choice.getObject("message");

    return message;
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.warn("Usage: {} [embed|prompt_gpt35|prompt_gpt4] <text>\n", .{args[0]});
        return;
    }

    const command = args[1];
    const text = args[2];

    if (std.mem.eql(u8, command, "embed")) {
        const embedding = try getEmbedding(allocator, text);
        std.debug.print("Embedding: {}\n", .{embedding});
    } else if (std.mem.eql(u8, command, "prompt_gpt35")) {
        const response = try getPromptResponse(allocator, text, 3);
        std.debug.print("GPT-3.5 Response: {}\n", .{response});
    } else if (std.mem.eql(u8, command, "prompt_gpt4")) {
        const response = try getPromptResponse(allocator, text, 4);
        std.debug.print("GPT-4 Response: {}\n", .{response});
    } else {
        std.debug.warn("Invalid command: {}\nUsage: {} [embed|prompt_gpt35|prompt_gpt4] <text>\n", .{ command, args[0] });
    }
}
